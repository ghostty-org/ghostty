const std = @import("std");
const testing = std.testing;
const Target = @import("target.zig").Target;

/// Create a struct type that is C ABI compatible from a Zig struct type.
///
/// When the target is `.zig`, the original struct type is returned as-is.
/// When the target is `.c`, the struct is recreated with an `extern` layout,
/// ensuring a stable, C-compatible memory layout.
///
/// This handles packed structs by resolving zero alignments to the natural
/// alignment of each field's type, since extern structs require explicit
/// alignment. This means packed struct fields like `bool` will take up
/// their full size (1 byte) rather than being bit-packed.
pub fn Struct(
    comptime target: Target,
    comptime Zig: type,
) type {
    return switch (target) {
        .zig => Zig,
        .c => c: {
            const info = @typeInfo(Zig).@"struct";
            var fields: [info.fields.len]std.builtin.Type.StructField = undefined;
            for (info.fields, 0..) |field, i| {
                fields[i] = .{
                    .name = field.name,
                    .type = field.type,
                    .default_value_ptr = field.default_value_ptr,
                    .is_comptime = field.is_comptime,
                    .alignment = if (field.alignment > 0) field.alignment else @alignOf(field.type),
                };
            }

            break :c @Type(.{ .@"struct" = .{
                .layout = .@"extern",
                .fields = &fields,
                .decls = &.{},
                .is_tuple = info.is_tuple,
            } });
        },
    };
}

test "packed struct converts to extern with full-size bools" {
    const Packed = packed struct {
        flag1: bool,
        flag2: bool,
        value: u8,
    };

    const C = Struct(.c, Packed);
    const info = @typeInfo(C).@"struct";

    try testing.expectEqual(.@"extern", info.layout);
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag1")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "flag2")));
    try testing.expectEqual(@as(usize, 1), @sizeOf(@FieldType(C, "value")));
    try testing.expectEqual(@as(usize, 3), @sizeOf(C));
}
