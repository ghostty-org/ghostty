const std = @import("std");
const Target = @import("target.zig").Target;

/// Create an enum type with the given keys that is C ABI compatible
/// if we're targeting C, otherwise a Zig enum with smallest possible
/// backing type.
///
/// In all cases, the enum keys will be created in the order given.
/// For C ABI, this means that the order MUST NOT be changed in order
/// to preserve ABI compatibility. You can set a key to null to
/// remove it from the Zig enum while keeping the "hole" in the C enum
/// to preserve ABI compatibility.
///
/// C detection is up to the caller, since there are multiple ways
/// to do that. We rely on the `target` parameter to determine whether we
/// should create a C compatible enum or a Zig enum.
///
/// For the Zig enum, the enum value is not guaranteed to be stable, so
/// it shouldn't be relied for things like serialization.
pub fn Enum(
    target: Target,
    keys: []const ?[:0]const u8,
) type {
    var fields: [keys.len]std.builtin.Type.EnumField = undefined;
    var fields_i: usize = 0;
    var holes: usize = 0;
    for (keys) |key_| {
        const key: [:0]const u8 = key_ orelse {
            switch (target) {
                // For Zig we don't track holes because the enum value
                // isn't guaranteed to be stable and we want to use the
                // smallest possible backing type.
                .zig => {},

                // For C we must track holes to preserve ABI compatibility
                // with subsequent values.
                .c => holes += 1,
            }
            continue;
        };

        fields[fields_i] = .{
            .name = key,
            .value = fields_i + holes,
        };
        fields_i += 1;
    }

    // Assigned to var so that the type name is nicer in stack traces.
    const Result = @Type(.{ .@"enum" = .{
        .tag_type = switch (target) {
            .c => c_int,
            .zig => std.math.IntFittingRange(0, fields_i - 1),
        },
        .fields = fields[0..fields_i],
        .decls = &.{},
        .is_exhaustive = true,
    } });
    return Result;
}

test "zig" {
    const testing = std.testing;
    const T = Enum(.zig, &.{ "a", "b", "c", "d" });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(u2, info.tag_type);
}

test "c" {
    const testing = std.testing;
    const T = Enum(.c, &.{ "a", "b", "c", "d" });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(c_int, info.tag_type);
}

test "abi by removing a key" {
    const testing = std.testing;
    // C
    {
        const T = Enum(.c, &.{ "a", "b", null, "d" });
        const info = @typeInfo(T).@"enum";
        try testing.expectEqual(c_int, info.tag_type);
        try testing.expectEqual(3, @intFromEnum(T.d));
    }

    // Zig
    {
        const T = Enum(.zig, &.{ "a", "b", null, "d" });
        const info = @typeInfo(T).@"enum";
        try testing.expectEqual(u2, info.tag_type);
        try testing.expectEqual(2, @intFromEnum(T.d));
    }
}

/// Verify that for every key in enum T, there is a matching declaration in
/// `ghostty.h` with the correct value. This should only ever be called inside a `test`
/// because the `ghostty.h` module is only available then.
pub fn checkGhosttyHEnum(comptime T: type, comptime prefix: []const u8) !void {
    const info = @typeInfo(T);

    try std.testing.expect(info == .@"enum");
    try std.testing.expect(info.@"enum".tag_type == c_int);
    try std.testing.expect(info.@"enum".is_exhaustive == true);

    @setEvalBranchQuota(1000000);

    const c = @import("ghostty.h");

    var set: std.EnumSet(T) = .initFull();

    const c_decls = @typeInfo(c).@"struct".decls;
    const enum_fields = info.@"enum".fields;

    inline for (enum_fields) |field| {
        const upper_name = comptime u: {
            var buf: [128]u8 = undefined;
            break :u std.ascii.upperString(&buf, field.name);
        };

        inline for (c_decls) |decl| {
            if (!comptime std.mem.startsWith(u8, decl.name, prefix)) continue;

            const suffix = decl.name[prefix.len..];

            if (!comptime std.mem.eql(u8, suffix, upper_name)) continue;

            std.testing.expectEqual(field.value, @field(c, decl.name)) catch |e| {
                std.log.err(@typeName(T) ++ " key " ++ field.name ++ " does not have the same backing int as " ++ decl.name, .{});
                return e;
            };

            set.remove(@enumFromInt(field.value));
        }
    }

    std.testing.expect(set.count() == 0) catch |e| {
        var it = set.iterator();
        while (it.next()) |v| {
            var buf: [128]u8 = undefined;
            const upper_string = std.ascii.upperString(&buf, @tagName(v));
            std.log.err("ghostty.h is missing value for {s}{s}", .{ prefix, upper_string });
        }
        return e;
    };
}
