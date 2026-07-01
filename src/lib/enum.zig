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
    var names_raw: [keys.len][]const u8 = undefined;
    var values_raw: [keys.len]comptime_int = undefined;
    const names_actual, const values_actual = kv: {
        // Remove any holes in the input (null values). As mentioned in the
        // function docs, in the event of the C ABI, we need to preserve the
        // original value, so we account for that.
        var to: comptime_int = 0;
        for (0..keys.len) |from| {
            if (keys[from]) |key| {
                names_raw[to] = key;
                values_raw[to] = if (target == .c) from else to;
                to += 1;
            }
        }

        break :kv .{ names_raw[0..to], values_raw[0..to] };
    };

    const TagInt = switch (target) {
        .c => c_int,
        .zig => std.math.IntFittingRange(0, names_actual.len - 1),
    };

    return @Enum(TagInt, .exhaustive, names_actual, &(values: {
        // We have to transform our comptime_int values into the actual int
        // we're creating the enum as.
        var result_int_values: [values_actual.len]TagInt = undefined;
        for (0..values_actual.len) |idx| {
            result_int_values[idx] = values_actual[idx];
        }
        break :values result_int_values;
    }));
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
pub fn checkGhosttyHEnum(
    comptime T: type,
    comptime prefix: []const u8,
) !void {
    const info = @typeInfo(T);

    try std.testing.expect(info == .@"enum");
    try std.testing.expect(info.@"enum".tag_type == c_int);
    try std.testing.expect(info.@"enum".is_exhaustive == true);

    @setEvalBranchQuota(100_000);

    const c = @import("ghostty.h");

    var set: std.EnumSet(T) = .initFull();

    const enum_fields = info.@"enum".fields;

    inline for (enum_fields) |field| {
        const expected_name: *const [prefix.len + field.name.len]u8 = comptime e: {
            var buf: [prefix.len + field.name.len]u8 = undefined;
            @memcpy(buf[0..prefix.len], prefix);
            for (buf[prefix.len..], field.name) |*d, s| {
                d.* = std.ascii.toUpper(s);
            }
            break :e &buf;
        };

        if (@hasDecl(c, expected_name)) {
            std.testing.expectEqual(field.value, @field(c, expected_name)) catch |e| {
                std.log.err(@typeName(T) ++ " key " ++ field.name ++ " does not have the same backing int as " ++ expected_name, .{});
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
