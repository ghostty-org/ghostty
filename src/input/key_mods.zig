const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const OptionAsAlt = @import("config.zig").OptionAsAlt;

/// Aliases for modifier names.
pub const alias: []const struct { []const u8, Mod } = &.{
    .{ "cmd", .super },
    .{ "command", .super },
    .{ "opt", .alt },
    .{ "option", .alt },
    .{ "control", .ctrl },
};

/// Single modifier
pub const Mod = enum {
    shift,
    ctrl,
    alt,
    super,

    pub const Side = enum(u1) { left, right };
};

/// A bitmask for all key modifiers.
///
/// IMPORTANT: Any changes here update include/ghostty.h
pub const Mods = packed struct(Mods.Backing) {
    pub const Backing = u16;

    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    sides: Side = .{},
    _padding: u6 = 0,

    /// The standard modifier keys only. Does not include the lock keys,
    /// only standard bindable keys.
    pub const Keys = packed struct(u4) {
        shift: bool = false,
        ctrl: bool = false,
        alt: bool = false,
        super: bool = false,

        pub const Backing = @typeInfo(Keys).@"struct".backing_integer.?;

        pub inline fn int(self: Keys) Keys.Backing {
            return @bitCast(self);
        }
    };

    /// Tracks the side that is active for any given modifier. Note
    /// that this doesn't confirm a modifier is pressed; you must check
    /// the bool for that in addition to this.
    ///
    /// Not all platforms support this, check apprt for more info.
    pub const Side = packed struct(u4) {
        shift: Mod.Side = .left,
        ctrl: Mod.Side = .left,
        alt: Mod.Side = .left,
        super: Mod.Side = .left,

        pub const Backing = @typeInfo(Side).@"struct".backing_integer.?;
    };

    /// The mask that has all the side bits set.
    pub const side_mask: Mods = .{
        .sides = .{
            .shift = .right,
            .ctrl = .right,
            .alt = .right,
            .super = .right,
        },
    };

    /// Integer value of this struct.
    pub fn int(self: Mods) Backing {
        return @bitCast(self);
    }

    /// Returns true if no modifiers are set.
    pub fn empty(self: Mods) bool {
        return self.int() == 0;
    }

    /// Returns true if two mods are equal.
    pub fn equal(self: Mods, other: Mods) bool {
        return self.int() == other.int();
    }

    /// Returns only the keys.
    ///
    /// In the future I want to remove `binding` for this. I didn't want
    /// to do that all in one PR where I added this because its a bigger
    /// change.
    pub fn keys(self: Mods) Keys {
        const backing: Keys.Backing = @truncate(self.int());
        return @bitCast(backing);
    }

    /// Return mods that are only relevant for bindings.
    pub fn binding(self: Mods) Mods {
        return .{
            .shift = self.shift,
            .ctrl = self.ctrl,
            .alt = self.alt,
            .super = self.super,
        };
    }

    /// Perform `self &~ other` to remove the other mods from self.
    pub fn unset(self: Mods, other: Mods) Mods {
        return @bitCast(self.int() & ~other.int());
    }

    /// Returns the mods without locks set.
    pub fn withoutLocks(self: Mods) Mods {
        var copy = self;
        copy.caps_lock = false;
        copy.num_lock = false;
        return copy;
    }

    /// Return the mods to use for key translation. This handles settings
    /// like macos-option-as-alt. The translation mods should be used for
    /// translation but never sent back in for the key callback.
    pub fn translation(self: Mods, option_as_alt: OptionAsAlt) Mods {
        var result = self;

        // macos-option-as-alt for darwin
        if (comptime builtin.target.os.tag.isDarwin()) alt: {
            // Alt has to be set only on the correct side
            switch (option_as_alt) {
                .false => break :alt,
                .true => {},
                .left => if (self.sides.alt == .right) break :alt,
                .right => if (self.sides.alt == .left) break :alt,
            }

            // Unset alt
            result.alt = false;
        }

        return result;
    }

    /// Checks to see if super is on (MacOS) or ctrl.
    pub fn ctrlOrSuper(self: Mods) bool {
        if (comptime builtin.target.os.tag.isDarwin()) {
            return self.super;
        }
        return self.ctrl;
    }

    // For our own understanding
    test {
        const testing = std.testing;
        try testing.expectEqual(@as(Backing, @bitCast(Mods{})), @as(Backing, 0b0));
        try testing.expectEqual(
            @as(Backing, @bitCast(Mods{ .shift = true })),
            @as(Backing, 0b0000_0001),
        );
    }

    test "translation macos-option-as-alt" {
        if (comptime !builtin.target.os.tag.isDarwin()) return error.SkipZigTest;

        const testing = std.testing;

        // Unset
        {
            const mods: Mods = .{};
            const result = mods.translation(.true);
            try testing.expectEqual(result, mods);
        }

        // Set
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{}, result);
        }

        // Set but disabled
        {
            const mods: Mods = .{ .alt = true };
            const result = mods.translation(.false);
            try testing.expectEqual(result, mods);
        }

        // Set wrong side
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .right } };
            const result = mods.translation(.left);
            try testing.expectEqual(result, mods);
        }
        {
            const mods: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
            const result = mods.translation(.right);
            try testing.expectEqual(result, mods);
        }

        // Set with other mods
        {
            const mods: Mods = .{ .alt = true, .shift = true };
            const result = mods.translation(.true);
            try testing.expectEqual(Mods{ .shift = true }, result);
        }
    }
};

/// Modifier remapping. See `key-remap` in Config.zig for detailed docs.
pub const RemapSet = struct {
    /// Available mappings.
    map: std.AutoArrayHashMapUnmanaged(Mods, Mods),

    /// The mask of remapped modifiers that can be used to quickly
    /// check if some input mods need remapping.
    mask: Mask,

    pub const empty: RemapSet = .{
        .map = .{},
        .mask = .{},
    };

    pub const ParseError = Allocator.Error || error{
        MissingAssignment,
        InvalidMod,
    };

    /// Parse from CLI input. Required by Config.
    pub fn parseCLI(self: *RemapSet, alloc: Allocator, input: ?[]const u8) !void {
        const value = input orelse "";

        // Empty value resets the set
        if (value.len == 0) {
            self.map.clearRetainingCapacity();
            self.mask = .{};
            return;
        }

        self.parse(alloc, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.MissingAssignment, error.InvalidMod => return error.InvalidValue,
        };
    }

    /// Parse a modifier remap and add it to the set.
    pub fn parse(
        self: *RemapSet,
        alloc: Allocator,
        input: []const u8,
    ) ParseError!void {
        // Find the assignment point ('=')
        const eql_idx = std.mem.indexOfScalar(
            u8,
            input,
            '=',
        ) orelse return error.MissingAssignment;

        // The to side defaults to "left" if no explicit side is given.
        // This is because this is the default unsided value provided by
        // the apprts in the current Mods layout.
        const to: Mods = to: {
            const raw = try parseMod(input[eql_idx + 1 ..]);
            break :to initMods(raw[0], raw[1] orelse .left);
        };

        // The from side, if sided, is easy and we put it directly into
        // the map.
        const from_raw = try parseMod(input[0..eql_idx]);
        if (from_raw[1]) |from_side| {
            const from: Mods = initMods(from_raw[0], from_side);
            try self.map.put(
                alloc,
                from,
                to,
            );
            errdefer comptime unreachable;
            self.mask.update(from);
            return;
        }

        // We need to do some combinatorial explosion here for unsided
        // from in order to assign all possible sides.
        const from_left = initMods(from_raw[0], .left);
        const from_right = initMods(from_raw[0], .right);
        try self.map.put(
            alloc,
            from_left,
            to,
        );
        errdefer _ = self.map.swapRemove(from_left);
        try self.map.put(
            alloc,
            from_right,
            to,
        );
        errdefer _ = self.map.swapRemove(from_right);

        errdefer comptime unreachable;
        self.mask.update(from_left);
        self.mask.update(from_right);
    }

    pub fn deinit(self: *RemapSet, alloc: Allocator) void {
        self.map.deinit(alloc);
    }

    /// Must be called prior to any remappings so that the mapping
    /// is sorted properly. Otherwise, you will get invalid results.
    pub fn finalize(self: *RemapSet) void {
        const Context = struct {
            keys: []const Mods,

            pub fn lessThan(
                ctx: @This(),
                a_index: usize,
                b_index: usize,
            ) bool {
                _ = b_index;

                // Mods with any right sides prioritize
                const side_mask = comptime Mods.side_mask.int();
                const a = ctx.keys[a_index];
                return a.int() & side_mask != 0;
            }
        };

        self.map.sort(Context{ .keys = self.map.keys() });
    }

    /// Deep copy of the struct. Required by Config.
    pub fn clone(self: *const RemapSet, alloc: Allocator) Allocator.Error!RemapSet {
        return .{
            .map = try self.map.clone(alloc),
            .mask = self.mask,
        };
    }

    /// Compare if two RemapSets are equal. Required by Config.
    pub fn equal(self: RemapSet, other: RemapSet) bool {
        if (self.map.count() != other.map.count()) return false;

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const other_value = other.map.get(entry.key_ptr.*) orelse return false;
            if (!entry.value_ptr.equal(other_value)) return false;
        }

        return true;
    }

    /// Used by Formatter. Required by Config.
    pub fn formatEntry(self: RemapSet, formatter: anytype) !void {
        if (self.map.count() == 0) {
            try formatter.formatEntry(void, {});
            return;
        }

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const from = entry.key_ptr.*;
            const to = entry.value_ptr.*;

            var buf: [64]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&buf);
            const writer = fbs.writer();
            formatMod(writer, from) catch return error.OutOfMemory;
            writer.writeByte('=') catch return error.OutOfMemory;
            formatMod(writer, to) catch return error.OutOfMemory;
            try formatter.formatEntry([]const u8, fbs.getWritten());
        }
    }

    fn formatMod(writer: anytype, mods: Mods) !void {
        // Check which mod is set and format it with optional side prefix
        inline for (.{ "shift", "ctrl", "alt", "super" }) |name| {
            if (@field(mods, name)) {
                const side = @field(mods.sides, name);
                if (side == .right) {
                    try writer.writeAll("right_");
                } else {
                    // Only write left_ if we need to distinguish
                    // For now, always write left_ if it's a sided mapping
                    try writer.writeAll("left_");
                }
                try writer.writeAll(name);
                return;
            }
        }
    }

    /// Parses a single mode in a single remapping string. E.g.
    /// `ctrl` or `left_shift`.
    fn parseMod(input: []const u8) error{InvalidMod}!struct { Mod, ?Mod.Side } {
        const side_str, const mod_str = if (std.mem.indexOfScalar(
            u8,
            input,
            '_',
        )) |idx| .{
            input[0..idx],
            input[idx + 1 ..],
        } else .{
            "",
            input,
        };

        const mod: Mod = if (std.meta.stringToEnum(
            Mod,
            mod_str,
        )) |mod| mod else mod: {
            inline for (alias) |pair| {
                if (std.mem.eql(u8, mod_str, pair[0])) {
                    break :mod pair[1];
                }
            }

            return error.InvalidMod;
        };

        return .{
            mod,
            if (side_str.len > 0) std.meta.stringToEnum(
                Mod.Side,
                side_str,
            ) orelse return error.InvalidMod else null,
        };
    }

    fn initMods(mod: Mod, side: Mod.Side) Mods {
        switch (mod) {
            inline else => |tag| {
                var mods: Mods = .{};
                @field(mods, @tagName(tag)) = true;
                @field(mods.sides, @tagName(tag)) = side;
                return mods;
            },
        }
    }

    /// Returns true if the given mods need remapping.
    pub fn isRemapped(self: *const RemapSet, mods: Mods) bool {
        return self.mask.match(mods);
    }

    /// Apply a remap to the given mods.
    pub fn apply(self: *const RemapSet, mods: Mods) Mods {
        if (!self.isRemapped(mods)) return mods;

        const mods_binding: Mods.Keys.Backing = @truncate(mods.int());
        const mods_sides: Mods.Side.Backing = @bitCast(mods.sides);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            const from = entry.key_ptr.*;
            const from_binding: Mods.Keys.Backing = @truncate(from.int());
            if (mods_binding & from_binding != from_binding) continue;
            const from_sides: Mods.Side.Backing = @bitCast(from.sides);
            if ((mods_sides ^ from_sides) & from_binding != 0) continue;

            var mods_int = mods.int();
            mods_int &= ~from.int();
            mods_int |= entry.value_ptr.int();
            return @bitCast(mods_int);
        }

        unreachable;
    }

    /// Tracks which modifier keys and sides have remappings registered.
    /// Used as a fast pre-check before doing expensive map lookups.
    ///
    /// The mask uses separate tracking for left and right sides because
    /// remappings can be side-specific (e.g., only remap left_ctrl).
    ///
    /// Note: `left_sides` uses inverted logic where 1 means "left is remapped"
    /// even though `Mod.Side.left = 0`. This allows efficient bitwise matching
    /// since we can AND directly with the side bits.
    pub const Mask = packed struct(u12) {
        /// Which modifier keys (shift/ctrl/alt/super) have any remapping.
        keys: Mods.Keys = .{},
        /// Which modifiers have left-side remappings (inverted: 1 = left remapped).
        left_sides: Mods.Side = .{},
        /// Which modifiers have right-side remappings (1 = right remapped).
        right_sides: Mods.Side = .{},

        /// Adds a modifier to the mask, marking it as having a remapping.
        pub fn update(self: *Mask, mods: Mods) void {
            const keys_int: Mods.Keys.Backing = mods.keys().int();

            // OR the new keys into our existing keys mask.
            // Example: keys=0b0000, new ctrl → keys=0b0010
            self.keys = @bitCast(self.keys.int() | keys_int);

            // Both Keys and Side are u4 with matching bit positions.
            // This lets us use keys_int to select which side bits to update.
            const sides: Mods.Side.Backing = @bitCast(mods.sides);
            const left_int: Mods.Side.Backing = @bitCast(self.left_sides);
            const right_int: Mods.Side.Backing = @bitCast(self.right_sides);

            // Update left_sides: set bit if this key is active AND side is left.
            // Since Side.left=0, we invert sides (~sides) so left becomes 1.
            // keys_int masks to only affect the modifier being added.
            // Example: left_ctrl → keys_int=0b0010, ~sides=0b1111 (left=0 inverted)
            //          result: left_int | (0b0010 & 0b1111) = left_int | 0b0010
            self.left_sides = @bitCast(left_int | (keys_int & ~sides));

            // Update right_sides: set bit if this key is active AND side is right.
            // Since Side.right=1, we use sides directly.
            // Example: right_ctrl → keys_int=0b0010, sides=0b0010 (right=1)
            //          result: right_int | (0b0010 & 0b0010) = right_int | 0b0010
            self.right_sides = @bitCast(right_int | (keys_int & sides));
        }

        /// Returns true if the given mods match any remapping in this mask.
        /// This is a fast check to avoid expensive map lookups when no
        /// remapping could possibly apply.
        ///
        /// Checks both that the modifier key is remapped AND that the
        /// specific side (left/right) being pressed has a remapping.
        pub fn match(self: *const Mask, mods: Mods) bool {
            // Find which pressed keys have remappings registered.
            // Example: pressed={ctrl,alt}, mask={ctrl} → active=0b0010 (just ctrl)
            const active = mods.keys().int() & self.keys.int();
            if (active == 0) return false;

            // Check if the pressed side matches a remapped side.
            // For left (sides bit = 0): check against left_int (where 1 = left remapped)
            //   ~sides inverts so left becomes 1, then AND with left_int
            // For right (sides bit = 1): check against right_int directly
            //
            // Example: pressing left_ctrl (sides.ctrl=0, left_int.ctrl=1)
            //   ~sides = 0b1111, left_int = 0b0010
            //   (~sides & left_int) = 0b0010 ✓ matches
            //
            // Example: pressing right_ctrl but only left_ctrl is remapped
            //   sides = 0b0010, left_int = 0b0010, right_int = 0b0000
            //   (~0b0010 & 0b0010) | (0b0010 & 0b0000) = 0b0000 ✗ no match
            const sides: Mods.Side.Backing = @bitCast(mods.sides);
            const left_int: Mods.Side.Backing = @bitCast(self.left_sides);
            const right_int: Mods.Side.Backing = @bitCast(self.right_sides);
            const side_match = (~sides & left_int) | (sides & right_int);

            // Final check: is any active (pressed + remapped) key also side-matched?
            return (active & side_match) != 0;
        }
    };
};

test "RemapSet: unsided remap creates both left and right mappings" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);
    try set.parse(alloc, "ctrl=super");
    set.finalize();
    try testing.expectEqual(
        Mods{
            .super = true,
            .sides = .{ .super = .left },
        },
        set.apply(.{
            .ctrl = true,
            .sides = .{ .ctrl = .left },
        }),
    );
    try testing.expectEqual(
        Mods{
            .super = true,
            .sides = .{ .super = .left },
        },
        set.apply(.{
            .ctrl = true,
            .sides = .{ .ctrl = .right },
        }),
    );
}

test "RemapSet: sided from only maps that side" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "left_alt=ctrl");
    set.finalize();

    const left_alt: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
    const left_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    try testing.expectEqual(left_ctrl, set.apply(left_alt));

    const right_alt: Mods = .{ .alt = true, .sides = .{ .alt = .right } };
    try testing.expectEqual(right_alt, set.apply(right_alt));
}

test "RemapSet: sided to" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "ctrl=right_super");
    set.finalize();

    const left_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    const right_super: Mods = .{ .super = true, .sides = .{ .super = .right } };
    try testing.expectEqual(right_super, set.apply(left_ctrl));
}

test "RemapSet: both sides specified" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "left_shift=right_ctrl");
    set.finalize();

    const left_shift: Mods = .{ .shift = true, .sides = .{ .shift = .left } };
    const right_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .right } };
    try testing.expectEqual(right_ctrl, set.apply(left_shift));
}

test "RemapSet: multiple parses accumulate" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "left_ctrl=super");
    try set.parse(alloc, "left_alt=ctrl");
    set.finalize();

    const left_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    try testing.expectEqual(left_super, set.apply(left_ctrl));

    const left_alt: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
    const left_ctrl_result: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    try testing.expectEqual(left_ctrl_result, set.apply(left_alt));
}

test "RemapSet: error on missing assignment" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try testing.expectError(error.MissingAssignment, set.parse(alloc, "ctrl"));
    try testing.expectError(error.MissingAssignment, set.parse(alloc, ""));
}

test "RemapSet: error on invalid modifier" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try testing.expectError(error.InvalidMod, set.parse(alloc, "invalid=ctrl"));
    try testing.expectError(error.InvalidMod, set.parse(alloc, "ctrl=invalid"));
    try testing.expectError(error.InvalidMod, set.parse(alloc, "middle_ctrl=super"));
}

test "RemapSet: isRemapped checks mask" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "ctrl=super");
    set.finalize();

    try testing.expect(set.isRemapped(.{ .ctrl = true }));
    try testing.expect(!set.isRemapped(.{ .alt = true }));
    try testing.expect(!set.isRemapped(.{ .shift = true }));
}

test "RemapSet: clone creates independent copy" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "ctrl=super");
    set.finalize();

    var cloned = try set.clone(alloc);
    defer cloned.deinit(alloc);

    try testing.expect(set.equal(cloned));
    try testing.expect(cloned.isRemapped(.{ .ctrl = true }));
}

test "RemapSet: equal compares correctly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set1: RemapSet = .empty;
    defer set1.deinit(alloc);

    var set2: RemapSet = .empty;
    defer set2.deinit(alloc);

    try testing.expect(set1.equal(set2));

    try set1.parse(alloc, "ctrl=super");
    try testing.expect(!set1.equal(set2));

    try set2.parse(alloc, "ctrl=super");
    try testing.expect(set1.equal(set2));

    try set1.parse(alloc, "alt=shift");
    try testing.expect(!set1.equal(set2));
}

test "RemapSet: parseCLI basic" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parseCLI(alloc, "ctrl=super");
    try testing.expectEqual(@as(usize, 2), set.map.count());
}

test "RemapSet: parseCLI empty clears" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parseCLI(alloc, "ctrl=super");
    try testing.expectEqual(@as(usize, 2), set.map.count());

    try set.parseCLI(alloc, "");
    try testing.expectEqual(@as(usize, 0), set.map.count());
}

test "RemapSet: parseCLI invalid" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try testing.expectError(error.InvalidValue, set.parseCLI(alloc, "foo=bar"));
    try testing.expectError(error.InvalidValue, set.parseCLI(alloc, "ctrl"));
}

test "RemapSet: parse aliased modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "cmd=ctrl");
    set.finalize();

    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    const left_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    try testing.expectEqual(left_ctrl, set.apply(left_super));
}

test "RemapSet: parse aliased modifiers command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "command=alt");
    set.finalize();

    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    const left_alt: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
    try testing.expectEqual(left_alt, set.apply(left_super));
}

test "RemapSet: parse aliased modifiers opt and option" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "opt=super");
    set.finalize();

    const left_alt: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    try testing.expectEqual(left_super, set.apply(left_alt));

    set.deinit(alloc);
    set = .empty;

    try set.parse(alloc, "option=shift");
    set.finalize();

    const left_shift: Mods = .{ .shift = true, .sides = .{ .shift = .left } };
    try testing.expectEqual(left_shift, set.apply(left_alt));
}

test "RemapSet: parse aliased modifiers control" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "control=super");
    set.finalize();

    const left_ctrl: Mods = .{ .ctrl = true, .sides = .{ .ctrl = .left } };
    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    try testing.expectEqual(left_super, set.apply(left_ctrl));
}

test "RemapSet: parse aliased modifiers on target side" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: RemapSet = .empty;
    defer set.deinit(alloc);

    try set.parse(alloc, "alt=cmd");
    set.finalize();

    const left_alt: Mods = .{ .alt = true, .sides = .{ .alt = .left } };
    const left_super: Mods = .{ .super = true, .sides = .{ .super = .left } };
    try testing.expectEqual(left_super, set.apply(left_alt));
}

test "RemapSet: formatEntry empty" {
    const testing = std.testing;
    const formatterpkg = @import("../config/formatter.zig");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    const set: RemapSet = .empty;
    try set.formatEntry(formatterpkg.entryFormatter("key-remap", &buf.writer));
    try testing.expectEqualSlices(u8, "key-remap = \n", buf.written());
}

test "RemapSet: formatEntry single sided" {
    const testing = std.testing;
    const formatterpkg = @import("../config/formatter.zig");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var set: RemapSet = .empty;
    defer set.deinit(testing.allocator);

    try set.parse(testing.allocator, "left_ctrl=super");
    set.finalize();

    try set.formatEntry(formatterpkg.entryFormatter("key-remap", &buf.writer));
    try testing.expectEqualSlices(u8, "key-remap = left_ctrl=left_super\n", buf.written());
}

test "RemapSet: formatEntry unsided creates two entries" {
    const testing = std.testing;
    const formatterpkg = @import("../config/formatter.zig");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var set: RemapSet = .empty;
    defer set.deinit(testing.allocator);

    try set.parse(testing.allocator, "ctrl=super");
    set.finalize();

    try set.formatEntry(formatterpkg.entryFormatter("key-remap", &buf.writer));
    // Unsided creates both left and right mappings
    const written = buf.written();
    try testing.expect(std.mem.indexOf(u8, written, "left_ctrl=left_super") != null);
    try testing.expect(std.mem.indexOf(u8, written, "right_ctrl=left_super") != null);
}

test "RemapSet: formatEntry right sided" {
    const testing = std.testing;
    const formatterpkg = @import("../config/formatter.zig");

    var buf: std.Io.Writer.Allocating = .init(testing.allocator);
    defer buf.deinit();

    var set: RemapSet = .empty;
    defer set.deinit(testing.allocator);

    try set.parse(testing.allocator, "left_alt=right_ctrl");
    set.finalize();

    try set.formatEntry(formatterpkg.entryFormatter("key-remap", &buf.writer));
    try testing.expectEqualSlices(u8, "key-remap = left_alt=right_ctrl\n", buf.written());
}
