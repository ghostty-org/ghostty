// The contents of this file is largely based on testing.zig from the Zig 0.15.1
// stdlib, distributed under the MIT license, copyright (c) Zig contributors
const std = @import("std");
const testing = std.testing;

/// A deep equality comparison function that works for most types. We
/// add types as necessary. It defers to `equal` decls on types that support
/// decls.
pub fn deepEqual(comptime T: type, old: T, new: T) bool {
    // Do known named types first
    switch (T) {
        inline []const u8,
        [:0]const u8,
        => return std.mem.eql(u8, old, new),

        []const [:0]const u8,
        => {
            if (old.len != new.len) return false;
            for (old, new) |a, b| {
                if (!std.mem.eql(u8, a, b)) return false;
            }

            return true;
        },

        else => {},
    }

    // Back into types of types
    switch (@typeInfo(T)) {
        .void => return true,

        inline .bool,
        .int,
        .float,
        .@"enum",
        => return old == new,

        .optional => |info| {
            if (old == null and new == null) return true;
            if (old == null or new == null) return false;
            return deepEqual(info.child, old.?, new.?);
        },

        .array => |info| for (old, new) |old_elem, new_elem| {
            if (!deepEqual(
                info.child,
                old_elem,
                new_elem,
            )) return false;
        } else return true,

        .@"struct" => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            // If a struct doesn't declare an "equal" function, we fall back
            // to a recursive field-by-field compare.
            inline for (info.fields) |field_info| {
                if (!deepEqual(
                    field_info.type,
                    @field(old, field_info.name),
                    @field(new, field_info.name),
                )) return false;
            }
            return true;
        },

        .@"union" => |info| {
            if (@hasDecl(T, "equal")) return old.equal(new);

            const tag_type = info.tag_type.?;
            const old_tag = std.meta.activeTag(old);
            const new_tag = std.meta.activeTag(new);
            if (old_tag != new_tag) return false;

            inline for (info.fields) |field_info| {
                if (@field(tag_type, field_info.name) == old_tag) {
                    return deepEqual(
                        field_info.type,
                        @field(old, field_info.name),
                        @field(new, field_info.name),
                    );
                }
            }

            unreachable;
        },

        else => {
            @compileLog(T);
            @compileError("unsupported field type");
        },
    }
}

/// Generic, recursive equality testing utility using approximate comparison for
/// floats and equality for everything else
///
/// Based on `testing.expectEqual` and `testing.expectEqualSlices`.
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
                testing.expectEqual(expected, actual) catch {
                    return error.TestExpectedApproxEqual;
                };
            }

            const Tag = std.meta.Tag(@TypeOf(expected));

            const expectedTag = @as(Tag, expected);
            const actualTag = @as(Tag, actual);

            testing.expectEqual(expectedTag, actualTag) catch {
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
            testing.expectEqual(expected, actual) catch {
                return error.TestExpectedApproxEqual;
            };
        },

        // fall back to expectEqual for everything else
        else => testing.expectEqual(expected, actual) catch {
            return error.TestExpectedApproxEqual;
        },
    }
}

/// Copy of testing.print (not public)
fn print(comptime fmt: []const u8, args: anytype) void {
    if (@inComptime()) {
        @compileError(std.fmt.comptimePrint(fmt, args));
    } else if (testing.backend_can_print) {
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

test "deepEqual void" {
    try testing.expect(deepEqual(void, {}, {}));
}

test "deepEqual bool" {
    try testing.expect(deepEqual(bool, true, true));
    try testing.expect(deepEqual(bool, false, false));
    try testing.expect(!deepEqual(bool, true, false));
    try testing.expect(!deepEqual(bool, false, true));
}

test "deepEqual int" {
    try testing.expect(deepEqual(i32, 42, 42));
    try testing.expect(deepEqual(i32, -100, -100));
    try testing.expect(!deepEqual(i32, 42, 43));
    try testing.expect(deepEqual(u64, 0, 0));
    try testing.expect(!deepEqual(u64, 0, 1));
}

test "deepEqual float" {
    try testing.expect(deepEqual(f32, 1.0, 1.0));
    try testing.expect(!deepEqual(f32, 1.0, 1.1));
    try testing.expect(deepEqual(f64, 3.14159, 3.14159));
    try testing.expect(!deepEqual(f64, 3.14159, 3.14158));
}

test "deepEqual enum" {
    const Color = enum { red, green, blue };
    try testing.expect(deepEqual(Color, .red, .red));
    try testing.expect(deepEqual(Color, .blue, .blue));
    try testing.expect(!deepEqual(Color, .red, .green));
    try testing.expect(!deepEqual(Color, .green, .blue));
}

test "deepEqual []const u8" {
    try testing.expect(deepEqual([]const u8, "hello", "hello"));
    try testing.expect(deepEqual([]const u8, "", ""));
    try testing.expect(!deepEqual([]const u8, "hello", "world"));
    try testing.expect(!deepEqual([]const u8, "hello", "hell"));
    try testing.expect(!deepEqual([]const u8, "hello", "hello!"));
}

test "deepEqual [:0]const u8" {
    try testing.expect(deepEqual([:0]const u8, "foo", "foo"));
    try testing.expect(!deepEqual([:0]const u8, "foo", "bar"));
    try testing.expect(!deepEqual([:0]const u8, "foo", "fo"));
}

test "deepEqual []const [:0]const u8" {
    const a: []const [:0]const u8 = &.{ "one", "two", "three" };
    const b: []const [:0]const u8 = &.{ "one", "two", "three" };
    const c: []const [:0]const u8 = &.{ "one", "two" };
    const d: []const [:0]const u8 = &.{ "one", "two", "four" };
    const e: []const [:0]const u8 = &.{};

    try testing.expect(deepEqual([]const [:0]const u8, a, b));
    try testing.expect(!deepEqual([]const [:0]const u8, a, c));
    try testing.expect(!deepEqual([]const [:0]const u8, a, d));
    try testing.expect(deepEqual([]const [:0]const u8, e, e));
    try testing.expect(!deepEqual([]const [:0]const u8, a, e));
}

test "deepEqual optional" {
    try testing.expect(deepEqual(?i32, null, null));
    try testing.expect(deepEqual(?i32, 42, 42));
    try testing.expect(!deepEqual(?i32, null, 42));
    try testing.expect(!deepEqual(?i32, 42, null));
    try testing.expect(!deepEqual(?i32, 42, 43));
}

test "deepEqual optional nested" {
    const Nested = struct { x: i32, y: i32 };
    try testing.expect(deepEqual(?Nested, null, null));
    try testing.expect(deepEqual(?Nested, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 2 }));
    try testing.expect(!deepEqual(?Nested, .{ .x = 1, .y = 2 }, .{ .x = 1, .y = 3 }));
    try testing.expect(!deepEqual(?Nested, .{ .x = 1, .y = 2 }, null));
}

test "deepEqual array" {
    try testing.expect(deepEqual([3]i32, .{ 1, 2, 3 }, .{ 1, 2, 3 }));
    try testing.expect(!deepEqual([3]i32, .{ 1, 2, 3 }, .{ 1, 2, 4 }));
    try testing.expect(!deepEqual([3]i32, .{ 1, 2, 3 }, .{ 0, 2, 3 }));
    try testing.expect(deepEqual([0]i32, .{}, .{}));
}

test "deepEqual nested array" {
    const a = [2][2]i32{ .{ 1, 2 }, .{ 3, 4 } };
    const b = [2][2]i32{ .{ 1, 2 }, .{ 3, 4 } };
    const c = [2][2]i32{ .{ 1, 2 }, .{ 3, 5 } };

    try testing.expect(deepEqual([2][2]i32, a, b));
    try testing.expect(!deepEqual([2][2]i32, a, c));
}

test "deepEqual struct" {
    const Point = struct { x: i32, y: i32 };
    try testing.expect(deepEqual(Point, .{ .x = 10, .y = 20 }, .{ .x = 10, .y = 20 }));
    try testing.expect(!deepEqual(Point, .{ .x = 10, .y = 20 }, .{ .x = 10, .y = 21 }));
    try testing.expect(!deepEqual(Point, .{ .x = 10, .y = 20 }, .{ .x = 11, .y = 20 }));
}

test "deepEqual struct nested" {
    const Inner = struct { value: i32 };
    const Outer = struct { a: Inner, b: Inner };

    const x = Outer{ .a = .{ .value = 1 }, .b = .{ .value = 2 } };
    const y = Outer{ .a = .{ .value = 1 }, .b = .{ .value = 2 } };
    const z = Outer{ .a = .{ .value = 1 }, .b = .{ .value = 3 } };

    try testing.expect(deepEqual(Outer, x, y));
    try testing.expect(!deepEqual(Outer, x, z));
}

test "deepEqual struct with equal decl" {
    const Custom = struct {
        value: i32,

        pub fn equal(self: @This(), other: @This()) bool {
            return @mod(self.value, 10) == @mod(other.value, 10);
        }
    };

    try testing.expect(deepEqual(Custom, .{ .value = 5 }, .{ .value = 15 }));
    try testing.expect(deepEqual(Custom, .{ .value = 100 }, .{ .value = 0 }));
    try testing.expect(!deepEqual(Custom, .{ .value = 5 }, .{ .value = 6 }));
}

test "deepEqual union" {
    const Value = union(enum) {
        int: i32,
        float: f32,
        none,
    };

    try testing.expect(deepEqual(Value, .{ .int = 42 }, .{ .int = 42 }));
    try testing.expect(!deepEqual(Value, .{ .int = 42 }, .{ .int = 43 }));
    try testing.expect(!deepEqual(Value, .{ .int = 42 }, .{ .float = 42.0 }));
    try testing.expect(deepEqual(Value, .none, .none));
    try testing.expect(!deepEqual(Value, .none, .{ .int = 0 }));
}

test "deepEqual union with equal decl" {
    const Value = union(enum) {
        num: i32,
        str: []const u8,

        pub fn equal(self: @This(), other: @This()) bool {
            return switch (self) {
                .num => |n| switch (other) {
                    .num => |m| @mod(n, 10) == @mod(m, 10),
                    else => false,
                },
                .str => |s| switch (other) {
                    .str => |t| s.len == t.len,
                    else => false,
                },
            };
        }
    };

    try testing.expect(deepEqual(Value, .{ .num = 5 }, .{ .num = 25 }));
    try testing.expect(!deepEqual(Value, .{ .num = 5 }, .{ .num = 6 }));
    try testing.expect(deepEqual(Value, .{ .str = "abc" }, .{ .str = "xyz" }));
    try testing.expect(!deepEqual(Value, .{ .str = "abc" }, .{ .str = "ab" }));
}

test "deepEqual array of structs" {
    const Item = struct { id: i32, name: []const u8 };
    const a = [2]Item{ .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "two" } };
    const b = [2]Item{ .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "two" } };
    const c = [2]Item{ .{ .id = 1, .name = "one" }, .{ .id = 2, .name = "TWO" } };

    try testing.expect(deepEqual([2]Item, a, b));
    try testing.expect(!deepEqual([2]Item, a, c));
}

test "deepEqual struct with optional field" {
    const Config = struct { name: []const u8, port: ?u16 };

    try testing.expect(deepEqual(Config, .{ .name = "app", .port = 8080 }, .{ .name = "app", .port = 8080 }));
    try testing.expect(deepEqual(Config, .{ .name = "app", .port = null }, .{ .name = "app", .port = null }));
    try testing.expect(!deepEqual(Config, .{ .name = "app", .port = 8080 }, .{ .name = "app", .port = null }));
    try testing.expect(!deepEqual(Config, .{ .name = "app", .port = 8080 }, .{ .name = "app", .port = 8081 }));
}

test "deepEqual struct with array field" {
    const Data = struct { values: [3]i32 };

    try testing.expect(deepEqual(Data, .{ .values = .{ 1, 2, 3 } }, .{ .values = .{ 1, 2, 3 } }));
    try testing.expect(!deepEqual(Data, .{ .values = .{ 1, 2, 3 } }, .{ .values = .{ 1, 2, 4 } }));
}
