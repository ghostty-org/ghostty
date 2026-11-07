const std = @import("std");
const build_options = @import("terminal_options");
const lib = @import("../lib/main.zig");

/// The target for the terminal lib in particular.
pub const target: lib.Target = if (build_options.c_abi) .c else .zig;

/// The calling convention to use for C APIs.
///
/// This is always .c for now. I want to make this "Zig" when we're not
/// building the C ABI but there are bigger issues we need to resolve to
/// make that possible (change it and see for yourself).
pub const calling_conv: std.lang.CallingConvention = .c;

/// An optional libghostty-vt feature. See `Options.Features`.
pub const Feature = std.meta.FieldEnum(@import("build_options.zig").Options.Features);

/// Whether feature `f` is compiled into this build.
///
/// Every C API function that belongs to a feature checks this as its
/// first statement. When the feature is off, the function returns right
/// away, usually with `.unsupported`:
///
/// ```zig
/// if (comptime !lib.feature(.snapshot)) return .unsupported;
/// ```
///
/// Keep the check `comptime`. Then the compiler skips the rest of the
/// function body when the feature is off, so the body may use code that
/// only exists in builds with the feature.
pub inline fn feature(comptime f: Feature) bool {
    return @field(build_options, @tagName(f));
}

/// Forwarded decls from lib that are used.
pub const alloc = lib.allocator;
pub const TinyIo = lib.TinyIo;
pub const Buffer = lib.Buffer;
pub const Enum = lib.Enum;
pub const parseInt = lib.parseInt;
pub const TaggedUnion = lib.TaggedUnion;
pub const Struct = lib.Struct;
pub const String = lib.String;
pub const checkGhosttyHEnum = lib.checkGhosttyHEnum;
pub const sizedBaseEnd = lib.sizedBaseEnd;
pub const sizedCheck = lib.sizedCheck;
pub const sizedField = lib.sizedField;
pub const sizedFieldFits = lib.sizedFieldFits;
pub const sizedSet = lib.sizedSet;
pub const sizedWrite = lib.sizedWrite;

/// A copy of the enum `E` that accepts any integer value.
///
/// C callers can pass any integer where the header declares an enum. If
/// that integer is not one of the enum's values and Zig reads it as an
/// exhaustive enum, the behavior is undefined. In release builds this can
/// silently take the wrong branch of a switch.
///
/// `CEnum(E)` has the same field names, values and backing integer as `E`,
/// but it is non-exhaustive, so every integer is a legal value of it. Use it
/// as the parameter type for enum values that come from C, then convert to
/// `E` with `enumFromC` before using the value. This keeps `E` itself
/// exhaustive for the rest of the codebase.
///
/// ```zig
/// pub fn set_action(
///     event_: Event,
///     action_: lib.CEnum(key.Action),
/// ) callconv(lib.calling_conv) Result {
///     const action = lib.enumFromC(key.Action, action_) orelse
///         return .invalid_value;
///     // `action` is now a valid key.Action.
/// }
/// ```
///
/// Because the field names match, Zig callers and tests can still pass
/// enum literals such as `.press`.
///
/// This is for enum values passed as data. Enums used as get/set keys are
/// declared non-exhaustive directly instead, so their dispatch switch can
/// return `.unsupported` from a `_` prong.
pub fn CEnum(comptime E: type) type {
    const info = @typeInfo(E).@"enum";
    const values = comptime values: {
        var result: [info.field_values.len]info.tag_type = undefined;
        for (&result, info.field_values) |*dst, v| dst.* = v;
        break :values result;
    };
    return @Enum(info.tag_type, .nonexhaustive, info.field_names, &values);
}

/// Convert a value that came from C to `E`. Returns null if the value is
/// not one of the values of `E`.
pub fn enumFromC(comptime E: type, value: CEnum(E)) ?E {
    const info = @typeInfo(E).@"enum";
    if (comptime info.mode == .nonexhaustive) return @fromBackingInt(@backingInt(value));
    if (comptime info.field_values.len == 0) return null;

    const min: i128, const max: i128 = comptime range: {
        var min: i128 = info.field_values[0];
        var max: i128 = min;
        for (info.field_values) |v| {
            min = @min(min, v);
            max = @max(max, v);
        }
        break :range .{ min, max };
    };

    const int = @backingInt(value);
    if (int < min or int > max) return null;

    // Enum values are unique, so the values are contiguous exactly when
    // there are as many of them as there are integers in the range.
    const span = max - min + 1;
    if (comptime span == info.field_values.len) return @fromBackingInt(int);

    // A sparse enum with a wide range would need a huge table. None of
    // the C API enums are like this today.
    if (comptime span > 1024) return std.enums.fromInt(E, int);

    const valid: [span]bool = comptime valid: {
        var result: [span]bool = @splat(false);
        for (info.field_values) |v| result[v - min] = true;
        break :valid result;
    };
    if (!valid[@intCast(int - min)]) return null;
    return @fromBackingInt(int);
}

/// Read an enum value that C passed through a pointer and convert it to
/// `E`. Returns null if the value is not one of the values of `E`.
///
/// Use this for enum values inside option values and input structs, where
/// the pointer is already typed as `*const E`. It reads the integer without
/// treating it as an `E` first, so an out-of-range value is safe to check.
///
/// ```zig
/// .macos_option_as_alt => opts.macos_option_as_alt =
///     lib.enumFromPtr(OptionAsAlt, value) orelse return .invalid_value,
/// ```
pub fn enumFromPtr(comptime E: type, ptr: *const E) ?E {
    const raw: *const CEnum(E) = @ptrCast(ptr);
    return enumFromC(E, raw.*);
}

test "enumFromC matches std.enums.fromInt" {
    const testing = std.testing;

    const Contiguous = enum(c_int) { a, b, c, d };
    const Negative = enum(c_int) { a = -2, b = -1, c = 0, d = 1 };
    const Sparse = enum(c_int) { a = 1, b = 3, c = 4, d = 10 };
    const Wide = enum(c_int) { a = -3, b = 5000 };
    const Single = enum(c_int) { a = 7 };
    const Byte = enum(u8) { a = 0, b = 254, c = 255 };

    inline for (.{ Contiguous, Negative, Sparse, Wide, Single, Byte }) |E| {
        const Tag = @typeInfo(E).@"enum".tag_type;
        const values = std.enums.values(E);
        var min: i64 = @backingInt(values[0]);
        var max: i64 = min;
        for (values) |v| {
            min = @min(min, @backingInt(v));
            max = @max(max, @backingInt(v));
        }

        // Every integer in the range, two past each end, and the ends of
        // the backing type.
        var i: i64 = min - 2;
        while (i <= max + 2) : (i += 1) {
            const int = std.math.cast(Tag, i) orelse continue;
            try testing.expectEqual(
                std.enums.fromInt(E, int),
                enumFromC(E, @fromBackingInt(int)),
            );
        }
        for ([_]Tag{ std.math.minInt(Tag), std.math.maxInt(Tag) }) |int| {
            try testing.expectEqual(
                std.enums.fromInt(E, int),
                enumFromC(E, @fromBackingInt(int)),
            );
        }
    }
}
