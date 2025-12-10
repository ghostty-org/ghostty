const std = @import("std");
const Target = @import("target.zig").Target;

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
                    .alignment = field.alignment,
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
