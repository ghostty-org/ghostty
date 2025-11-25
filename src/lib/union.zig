const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const testing = std.testing;
const Target = @import("target.zig").Target;

/// Create a tagged union type that supports a C ABI and maintains
/// C ABI compatibility when adding new tags. This returns a set of types
/// and functions to augment the given Union type, not create a wholly new
/// union type.
///
/// The C ABI compatible types and functions are only available when the
/// target produces C values.
///
/// The `Union` type should be a standard Zig tagged union. The tag type
/// should be explicit (i.e. not `union(enum)`) and the tag type should
/// be an enum created with the `Enum` function in this library, so that
/// automatic C ABI compatibility is ensured.
///
/// The `Padding` type is a type that is always added to the C union
/// with the key `_padding`. This should be set to a type that has the size
/// and alignment needed to pad the C union to the expected size. This
/// should never change to ensure ABI compatibility.
pub fn TaggedUnion(
    comptime target: Target,
    comptime Union: type,
    comptime Padding: type,
) type {
    return struct {
        comptime {
            switch (target) {
                .zig => {},

                // For ABI compatibility, we expect that this is our union size.
                .c => if (@sizeOf(CValue) != @sizeOf(Padding)) {
                    @compileLog(@sizeOf(CValue));
                    @compileError("TaggedUnion CValue size does not match expected fixed size");
                },
            }
        }

        /// The tag type.
        pub const Tag = @typeInfo(Union).@"union".tag_type.?;

        /// The Zig union.
        pub const Zig = Union;

        /// The C ABI compatible tagged union type.
        pub const C = switch (target) {
            .zig => struct {},
            .c => extern struct {
                tag: Tag,
                value: CValue,
            },
        };

        /// The C ABI compatible union value type.
        pub const CValue = cvalue: {
            switch (target) {
                .zig => break :cvalue extern struct {},
                .c => {},
            }

            const tag_fields = @typeInfo(Tag).@"enum".fields;
            var union_fields: [tag_fields.len + 1]std.builtin.Type.UnionField = undefined;
            for (tag_fields, 0..) |field, i| {
                const action = @unionInit(Union, field.name, undefined);
                const Type = t: {
                    const Type = @TypeOf(@field(action, field.name));
                    // Types can provide custom types for their CValue.
                    switch (@typeInfo(Type)) {
                        .@"enum", .@"struct", .@"union" => if (@hasDecl(Type, "C")) break :t Type.C,
                        else => {},
                    }

                    break :t Type;
                };

                union_fields[i] = .{
                    .name = field.name,
                    .type = Type,
                    .alignment = @alignOf(Type),
                };
            }

            union_fields[tag_fields.len] = .{
                .name = "_padding",
                .type = Padding,
                .alignment = @alignOf(Padding),
            };

            break :cvalue @Type(.{ .@"union" = .{
                .layout = .@"extern",
                .tag_type = null,
                .fields = &union_fields,
                .decls = &.{},
            } });
        };

        /// Convert to C union.
        pub fn cval(self: Union) C {
            const value: CValue = switch (self) {
                inline else => |v, tag| @unionInit(
                    CValue,
                    @tagName(tag),
                    value: {
                        switch (@typeInfo(@TypeOf(v))) {
                            .@"enum", .@"struct", .@"union" => if (@hasDecl(@TypeOf(v), "cval")) break :value v.cval(),
                            else => {},
                        }

                        break :value v;
                    },
                ),
            };

            return .{
                .tag = @as(Tag, self),
                .value = value,
            };
        }

        /// Returns the value type for the given tag.
        pub fn Value(comptime tag: Tag) type {
            @setEvalBranchQuota(10000);
            inline for (@typeInfo(Union).@"union".fields) |field| {
                const field_tag = @field(Tag, field.name);
                if (field_tag == tag) return field.type;
            }

            unreachable;
        }
    };
}

test "TaggedUnion: matching size" {
    const Tag = enum(c_int) { a, b };
    const U = TaggedUnion(
        .c,
        union(Tag) {
            a: u32,
            b: u64,
        },
        u64,
    );

    try testing.expectEqual(8, @sizeOf(U.CValue));
}

test "TaggedUnion: padded size" {
    const Tag = enum(c_int) { a };
    const U = TaggedUnion(
        .c,
        union(Tag) {
            a: u32,
        },
        u64,
    );

    try testing.expectEqual(8, @sizeOf(U.CValue));
}

test "TaggedUnion: c conversion" {
    const Tag = enum(c_int) { a, b };
    const U = TaggedUnion(.c, union(Tag) {
        a: u32,
        b: u64,
    }, u64);

    const c = U.cval(.{ .a = 42 });
    try testing.expectEqual(Tag.a, c.tag);
    try testing.expectEqual(42, c.value.a);
}
