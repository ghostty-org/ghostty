const std = @import("std");
const builtin = @import("builtin");

const Target = @import("target.zig").Target;

const std_enums = @import("std_enums.zig");

/// Create an enum type with the given keys that is C ABI compatible
/// if we're targeting C, otherwise a Zig enum with smallest possible
/// backing type.
///
/// In all cases, each enum value is its index in `keys`. The order MUST NOT
/// be changed when the integer values are part of an ABI or serialized format.
/// A null key removes that field while preserving its integer hole.
///
/// C detection is up to the caller, since there are multiple ways
/// to do that. We rely on the `target` parameter to determine whether we
/// should create a C compatible enum or a Zig enum.
///
/// C enums use `c_int`. Zig enums use the smallest unsigned integer that can
/// represent every key index, including holes.
pub fn Enum(
    target: Target,
    keys: []const ?[:0]const u8,
) type {
    var names_raw: [keys.len][]const u8 = undefined;
    var values_raw: [keys.len]comptime_int = undefined;
    const names_actual, const values_actual = kv: {
        // Remove null fields while preserving their positions as integer holes.
        var to: comptime_int = 0;
        for (0..keys.len) |from| {
            if (keys[from]) |key| {
                names_raw[to] = key;
                values_raw[to] = from;
                to += 1;
            }
        }

        break :kv .{ names_raw[0..to], values_raw[0..to] };
    };

    const TagInt = switch (target) {
        .c => c_int,
        .zig => std.math.IntFittingRange(0, keys.len - 1),
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

test "stable values when removing a key" {
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
        try testing.expectEqual(3, @intFromEnum(T.d));
    }
}

test "zig backing integer includes trailing holes" {
    const testing = std.testing;
    const T = Enum(.zig, &.{ "a", null, null, null, null });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(u3, info.tag_type);
    try testing.expectEqual(0, @intFromEnum(T.a));
}

test "zig values remain stable across multiple holes" {
    const testing = std.testing;
    const T = Enum(.zig, &.{ null, "b", null, "d", null, "f" });
    const info = @typeInfo(T).@"enum";
    try testing.expectEqual(u3, info.tag_type);
    try testing.expectEqual(1, @intFromEnum(T.b));
    try testing.expectEqual(3, @intFromEnum(T.d));
    try testing.expectEqual(5, @intFromEnum(T.f));
}

const CheckError = error{ SkipZigTest, TestExpectedEqual, TestUnexpectedResult };

fn ghosttyHEnumCheck(expected: anytype, actual: anytype) CheckError!void {
    try std.testing.expectEqual(expected, actual);
}

/// Verify that for every key in enum T, there is a matching declaration in
/// `ghostty.h` with the correct value. This should only ever be called inside a `test`
/// because the `ghostty.h` module is only available then.
pub fn checkGhosttyHEnum(comptime T: type, comptime prefix: []const u8) CheckError!void {
    // these targets don't support libc, which is required for this test
    if (comptime builtin.cpu.arch.isWasm()) return error.SkipZigTest;
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    try checkEnum("ghostty.h", @import("ghostty-h"), T, null, prefix, ghosttyHEnumCheck);
}

/// Verify that for every key in enum T, there is a matching macro in
/// `ghostty/vt.h`. This should only ever be called inside a `test` because the
/// `ghostty/vt.h` module is only available then. The actual value of the macro
/// is not checked as the value of the macro may be more complex than an integer
/// that matches the Zig enum.
pub fn checkGhosttyVtHMacroExists(comptime T: type, comptime prefix: []const u8) CheckError!void {
    // these targets don't support libc, which is required for this test
    if (comptime builtin.cpu.arch.isWasm()) return error.SkipZigTest;
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    try checkEnum("ghostty/vt.h", @import("ghostty-vt-h"), T, null, prefix, null);
}

fn checkEnum(
    comptime name: []const u8,
    comptime c: anytype,
    comptime T: type,
    comptime backint_int_type_: ?type,
    comptime prefix: []const u8,
    comptime check_: ?fn (anytype, anytype) CheckError!void,
) !void {
    const info = @typeInfo(T);

    try std.testing.expect(info == .@"enum");
    if (backint_int_type_) |backing_int_type|
        try std.testing.expect(info.@"enum".tag_type == backing_int_type);
    try std.testing.expect(info.@"enum".is_exhaustive == true);

    @setEvalBranchQuota(100_000);

    var set: std_enums.EnumSet(T) = .initFull();

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
                std.log.err(
                    "{s} key {s} does not have the same backing int as " ++ expected_name,
                    .{ @typeName(T), field.name },
                );
                return e;
            };
            if (check_) |check| {
                check(
                    field.value,
                    @field(c, expected_name),
                ) catch |e| {
                    std.log.err("{s} key {s} / " ++ expected_name ++ " failed its check: {t}", .{ @typeName(T), field.name, e });
                    return e;
                };
            }

            set.remove(@enumFromInt(field.value));
        }
    }

    std.testing.expect(set.count() == 0) catch |e| {
        var it = set.iterator();
        while (it.next()) |v| {
            var buf: [128]u8 = undefined;
            const upper_string = std.ascii.upperString(&buf, @tagName(v));
            std.log.err("{s} is missing value for {s}{s}", .{ name, prefix, upper_string });
        }
        return e;
    };
}
