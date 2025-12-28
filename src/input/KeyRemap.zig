//! Key remapping support for modifier keys within Ghostty.
//!
//! This module allows users to remap modifier keys (ctrl, alt, shift, super)
//! at the application level without affecting system-wide settings.
//!
//! Syntax: `key-remap = from=to`
//!
//! Examples:
//!   key-remap = ctrl=super     -- Ctrl acts as Super
//!   key-remap = left_alt=ctrl  -- Left Alt acts as Ctrl
//!
//! Remapping is one-way and non-transitive:
//!   - `ctrl=super` means Ctrl→Super, but Super stays Super
//!   - `ctrl=super` + `alt=ctrl` means Alt→Ctrl (NOT Super)

const KeyRemap = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const key = @import("key.zig");
const Mods = key.Mods;

from: ModKey,
to: ModKey,

pub const ModKey = enum {
    ctrl,
    alt,
    shift,
    super,
    left_ctrl,
    left_alt,
    left_shift,
    left_super,
    right_ctrl,
    right_alt,
    right_shift,
    right_super,

    pub fn isGeneric(self: ModKey) bool {
        return switch (self) {
            .ctrl, .alt, .shift, .super => true,
            else => false,
        };
    }

    pub fn parse(input: []const u8) ?ModKey {
        const map = std.StaticStringMap(ModKey).initComptime(.{
            .{ "ctrl", .ctrl },
            .{ "control", .ctrl },
            .{ "alt", .alt },
            .{ "opt", .alt },
            .{ "option", .alt },
            .{ "shift", .shift },
            .{ "super", .super },
            .{ "cmd", .super },
            .{ "command", .super },
            .{ "left_ctrl", .left_ctrl },
            .{ "left_control", .left_ctrl },
            .{ "leftctrl", .left_ctrl },
            .{ "leftcontrol", .left_ctrl },
            .{ "left_alt", .left_alt },
            .{ "left_opt", .left_alt },
            .{ "left_option", .left_alt },
            .{ "leftalt", .left_alt },
            .{ "leftopt", .left_alt },
            .{ "leftoption", .left_alt },
            .{ "left_shift", .left_shift },
            .{ "leftshift", .left_shift },
            .{ "left_super", .left_super },
            .{ "left_cmd", .left_super },
            .{ "left_command", .left_super },
            .{ "leftsuper", .left_super },
            .{ "leftcmd", .left_super },
            .{ "leftcommand", .left_super },
            .{ "right_ctrl", .right_ctrl },
            .{ "right_control", .right_ctrl },
            .{ "rightctrl", .right_ctrl },
            .{ "rightcontrol", .right_ctrl },
            .{ "right_alt", .right_alt },
            .{ "right_opt", .right_alt },
            .{ "right_option", .right_alt },
            .{ "rightalt", .right_alt },
            .{ "rightopt", .right_alt },
            .{ "rightoption", .right_alt },
            .{ "right_shift", .right_shift },
            .{ "rightshift", .right_shift },
            .{ "right_super", .right_super },
            .{ "right_cmd", .right_super },
            .{ "right_command", .right_super },
            .{ "rightsuper", .right_super },
            .{ "rightcmd", .right_super },
            .{ "rightcommand", .right_super },
        });

        var buf: [32]u8 = undefined;
        if (input.len > buf.len) return null;
        const lower = std.ascii.lowerString(&buf, input);
        return map.get(lower);
    }
};

pub fn parse(input: []const u8) !KeyRemap {
    const eql_idx = std.mem.indexOf(u8, input, "=") orelse
        return error.InvalidFormat;

    const from_str = std.mem.trim(u8, input[0..eql_idx], " \t");
    const to_str = std.mem.trim(u8, input[eql_idx + 1 ..], " \t");

    if (from_str.len == 0 or to_str.len == 0) {
        return error.InvalidFormat;
    }

    const from = ModKey.parse(from_str) orelse return error.InvalidModifier;
    const to = ModKey.parse(to_str) orelse return error.InvalidModifier;

    return .{ .from = from, .to = to };
}

pub fn apply(self: KeyRemap, mods: Mods) ?Mods {
    var result = mods;
    var matched = false;

    switch (self.from) {
        .ctrl => if (mods.ctrl) {
            result.ctrl = false;
            matched = true;
        },
        .left_ctrl => if (mods.ctrl and mods.sides.ctrl == .left) {
            result.ctrl = false;
            matched = true;
        },
        .right_ctrl => if (mods.ctrl and mods.sides.ctrl == .right) {
            result.ctrl = false;
            matched = true;
        },
        .alt => if (mods.alt) {
            result.alt = false;
            matched = true;
        },
        .left_alt => if (mods.alt and mods.sides.alt == .left) {
            result.alt = false;
            matched = true;
        },
        .right_alt => if (mods.alt and mods.sides.alt == .right) {
            result.alt = false;
            matched = true;
        },
        .shift => if (mods.shift) {
            result.shift = false;
            matched = true;
        },
        .left_shift => if (mods.shift and mods.sides.shift == .left) {
            result.shift = false;
            matched = true;
        },
        .right_shift => if (mods.shift and mods.sides.shift == .right) {
            result.shift = false;
            matched = true;
        },
        .super => if (mods.super) {
            result.super = false;
            matched = true;
        },
        .left_super => if (mods.super and mods.sides.super == .left) {
            result.super = false;
            matched = true;
        },
        .right_super => if (mods.super and mods.sides.super == .right) {
            result.super = false;
            matched = true;
        },
    }

    if (!matched) return null;

    switch (self.to) {
        .ctrl, .left_ctrl => {
            result.ctrl = true;
            result.sides.ctrl = .left;
        },
        .right_ctrl => {
            result.ctrl = true;
            result.sides.ctrl = .right;
        },
        .alt, .left_alt => {
            result.alt = true;
            result.sides.alt = .left;
        },
        .right_alt => {
            result.alt = true;
            result.sides.alt = .right;
        },
        .shift, .left_shift => {
            result.shift = true;
            result.sides.shift = .left;
        },
        .right_shift => {
            result.shift = true;
            result.sides.shift = .right;
        },
        .super, .left_super => {
            result.super = true;
            result.sides.super = .left;
        },
        .right_super => {
            result.super = true;
            result.sides.super = .right;
        },
    }

    return result;
}

/// Apply remaps non-transitively: each remap checks the original mods.
pub fn applyRemaps(remaps: []const KeyRemap, mods: Mods) Mods {
    var result = mods;
    for (remaps) |remap| {
        if (remap.apply(mods)) |_| {
            switch (remap.from) {
                .ctrl, .left_ctrl, .right_ctrl => result.ctrl = false,
                .alt, .left_alt, .right_alt => result.alt = false,
                .shift, .left_shift, .right_shift => result.shift = false,
                .super, .left_super, .right_super => result.super = false,
            }
            switch (remap.to) {
                .ctrl, .left_ctrl => {
                    result.ctrl = true;
                    result.sides.ctrl = .left;
                },
                .right_ctrl => {
                    result.ctrl = true;
                    result.sides.ctrl = .right;
                },
                .alt, .left_alt => {
                    result.alt = true;
                    result.sides.alt = .left;
                },
                .right_alt => {
                    result.alt = true;
                    result.sides.alt = .right;
                },
                .shift, .left_shift => {
                    result.shift = true;
                    result.sides.shift = .left;
                },
                .right_shift => {
                    result.shift = true;
                    result.sides.shift = .right;
                },
                .super, .left_super => {
                    result.super = true;
                    result.sides.super = .left;
                },
                .right_super => {
                    result.super = true;
                    result.sides.super = .right;
                },
            }
        }
    }
    return result;
}

pub fn clone(self: KeyRemap, alloc: Allocator) Allocator.Error!KeyRemap {
    _ = alloc;
    return self;
}

pub fn equal(self: KeyRemap, other: KeyRemap) bool {
    return self.from == other.from and self.to == other.to;
}

test "ModKey.parse" {
    const testing = std.testing;

    try testing.expectEqual(ModKey.ctrl, ModKey.parse("ctrl").?);
    try testing.expectEqual(ModKey.ctrl, ModKey.parse("control").?);
    try testing.expectEqual(ModKey.ctrl, ModKey.parse("CTRL").?);
    try testing.expectEqual(ModKey.alt, ModKey.parse("alt").?);
    try testing.expectEqual(ModKey.super, ModKey.parse("cmd").?);
    try testing.expectEqual(ModKey.left_ctrl, ModKey.parse("left_ctrl").?);
    try testing.expectEqual(ModKey.right_alt, ModKey.parse("right_alt").?);
    try testing.expect(ModKey.parse("foo") == null);
}

test "parse" {
    const testing = std.testing;

    const remap = try parse("ctrl=super");
    try testing.expectEqual(ModKey.ctrl, remap.from);
    try testing.expectEqual(ModKey.super, remap.to);

    const spaced = try parse("  ctrl  =  super  ");
    try testing.expectEqual(ModKey.ctrl, spaced.from);

    try testing.expectError(error.InvalidFormat, parse("ctrl"));
    try testing.expectError(error.InvalidModifier, parse("foo=bar"));
}

test "apply" {
    const testing = std.testing;

    const remap = try parse("ctrl=super");
    const mods = Mods{ .ctrl = true };
    const result = remap.apply(mods).?;

    try testing.expect(!result.ctrl);
    try testing.expect(result.super);
    try testing.expect(remap.apply(Mods{ .alt = true }) == null);
}

test "applyRemaps non-transitive" {
    const testing = std.testing;

    const remaps = [_]KeyRemap{
        try parse("ctrl=super"),
        try parse("alt=ctrl"),
    };

    const mods = Mods{ .alt = true };
    const result = applyRemaps(&remaps, mods);

    try testing.expect(!result.alt);
    try testing.expect(result.ctrl);
    try testing.expect(!result.super);
}
