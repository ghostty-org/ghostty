const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Conditionals in Ghostty configuration are based on a static, typed
/// state of the world instead of a dynamic key-value set. This simplifies
/// the implementation, allows for better type checking, and enables a
/// typed C API.
pub const State = struct {
    /// The theme of the underlying OS desktop environment.
    theme: Theme = .light,

    /// The target OS of the current build.
    os: std.Target.Os.Tag = builtin.target.os.tag,

    pub const Theme = enum { light, dark };

    /// Tests the conditional against the state and returns true if it matches.
    pub fn match(self: State, cond: Conditional) bool {
        switch (cond.key) {
            inline else => |tag| {
                // The raw value of the state field.
                const raw = @field(self, @tagName(tag));

                // Since all values are enums currently then we can just
                // do this. If we introduce non-enum state values then this
                // will be a compile error and we should fix here.
                const value: []const u8 = @tagName(raw);

                return switch (cond.op) {
                    .eq => std.mem.eql(u8, value, cond.value),
                    .ne => !std.mem.eql(u8, value, cond.value),
                };
            },
        }
    }
};

/// An enum of the available conditional configuration keys.
pub const Key = key: {
    const stateInfo = @typeInfo(State).@"struct";
    var fields: [stateInfo.fields.len]std.builtin.Type.EnumField = undefined;
    for (stateInfo.fields, 0..) |field, i| fields[i] = .{
        .name = field.name,
        .value = i,
    };

    break :key @Type(.{ .@"enum" = .{
        .tag_type = std.math.IntFittingRange(0, fields.len - 1),
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// A single conditional that can be true or false.
pub const Conditional = struct {
    key: Key,
    op: Op,
    value: []const u8,

    pub const Op = enum { eq, ne };

    pub fn clone(
        self: Conditional,
        alloc: Allocator,
    ) Allocator.Error!Conditional {
        return .{
            .key = self.key,
            .op = self.op,
            .value = try alloc.dupe(u8, self.value),
        };
    }
};

test "conditional enum match" {
    const testing = std.testing;
    const state: State = .{ .theme = .dark };
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .eq,
        .value = "dark",
    }));
    try testing.expect(!state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "dark",
    }));
    try testing.expect(state.match(.{
        .key = .theme,
        .op = .ne,
        .value = "light",
    }));
}
