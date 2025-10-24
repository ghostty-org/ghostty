// The contents of this file is largely based on testing.zig from the Zig 0.15.1
// stdlib, distributed under the MIT license, copyright (c) Zig contributors
const std = @import("std");

/// Generic, recursive equality testing utility using approximate comparison for
/// floats and equality for everything else
///
/// Based on `std.testing.expectEqual` and `std.testing.expectEqualSlices`.
///
/// The relative tolerance is currently hardcoded to `sqrt(eps(float_type))`.
pub inline fn expectApproxEqual(expected: anytype, actual: anytype) !void {
    const T = @TypeOf(expected, actual);
    return expectApproxEqualInner(T, expected, actual);
}

fn expectApproxEqualInner(comptime T: type, expected: T, actual: T) !void {
    switch (@typeInfo(T)) {
        // check approximate equality for floats
        .float => {
            const sqrt_eps = comptime std.math.sqrt(std.math.floatEps(T));
            if (!std.math.approxEqRel(T, expected, actual, sqrt_eps)) {
                print("expected approximately {any}, found {any}\n", .{ expected, actual });
                return error.TestExpectedApproxEqual;
            }
        },

        // recurse into containers
        .array => {
            const diff_index: usize = diff_index: {
                const shortest = @min(expected.len, actual.len);
                var index: usize = 0;
                while (index < shortest) : (index += 1) {
                    expectApproxEqual(actual[index], expected[index]) catch break :diff_index index;
                }
                break :diff_index if (expected.len == actual.len) return else shortest;
            };
            print("slices not approximately equal. first significant difference occurs at index {d} (0x{X})\n", .{ diff_index, diff_index });
            return error.TestExpectedApproxEqual;
        },
        .vector => |info| {
            var i: usize = 0;
            while (i < info.len) : (i += 1) {
                expectApproxEqual(expected[i], actual[i]) catch {
                    print("index {d} incorrect. expected approximately {any}, found {any}\n", .{
                        i, expected[i], actual[i],
                    });
                    return error.TestExpectedApproxEqual;
                };
            }
        },
        .@"struct" => |structType| {
            inline for (structType.fields) |field| {
                try expectApproxEqual(@field(expected, field.name), @field(actual, field.name));
            }
        },

        // unwrap unions, optionals, and error unions
        .@"union" => |union_info| {
            if (union_info.tag_type == null) {
                // untagged unions can only be compared bitwise,
                // so expectEqual is all we need
                std.testing.expectEqual(expected, actual) catch {
                    return error.TestExpectedApproxEqual;
                };
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            std.testing.expectEqual(expectedTag, actualTag) catch {
                return error.TestExpectedApproxEqual;
            };

            // we only reach this switch if the tags are equal
            switch (expected) {
                inline else => |val, tag| try expectApproxEqual(val, @field(actual, @tagName(tag))),
            }
        },
        .optional, .error_union => {
            if (expected) |expected_payload| if (actual) |actual_payload| {
                return expectApproxEqual(expected_payload, actual_payload);
            };
            // we only reach this point if there's at least one null or error,
            // in which case expectEqual is all we need
            std.testing.expectEqual(expected, actual) catch {
                return error.TestExpectedApproxEqual;
            };
        },

        // fall back to expectEqual for everything else
        else => std.testing.expectEqual(expected, actual) catch {
            return error.TestExpectedApproxEqual;
        },
    }
}

/// Copy of std.testing.print (not public)
fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (std.testing.backend_can_print) {
        std.debug.print(fmt, args);
    }
}

// Tests based on the `expectEqual` tests in the Zig stdlib
test "expectApproxEqual.union(enum)" {
    const T = union(enum) {
        a: i32,
        b: f32,
    };

    const b10 = T{ .b = 10.0 };
    const b10plus = T{ .b = 10.000001 };

    try expectApproxEqual(b10, b10plus);
}

test "expectApproxEqual nested array" {
    const a = [2][2]f32{
        [_]f32{ 1.0, 0.0 },
        [_]f32{ 0.0, 1.0 },
    };

    const b = [2][2]f32{
        [_]f32{ 1.000001, 0.0 },
        [_]f32{ 0.0, 0.999999 },
    };

    try expectApproxEqual(a, b);
}

test "expectApproxEqual vector" {
    const a: @Vector(4, f32) = @splat(4.0);
    const b: @Vector(4, f32) = @splat(4.000001);

    try expectApproxEqual(a, b);
}

test "expectApproxEqual struct" {
    const a = .{ 1, @as(f32, 1.0) };
    const b = .{ 1, @as(f32, 0.999999) };

    try expectApproxEqual(a, b);
}
