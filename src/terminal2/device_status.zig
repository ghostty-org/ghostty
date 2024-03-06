const std = @import("std");

/// An enum(u16) of the available device status requests.
pub const Request = dsr_enum: {
    const EnumField = std.builtin.Type.EnumField;
    var fields: [entries.len]EnumField = undefined;
    for (entries, 0..) |entry, i| {
        fields[i] = .{
            .name = entry.name,
            .value = @as(Tag.Backing, @bitCast(Tag{
                .value = entry.value,
                .question = entry.question,
            })),
        };
    }

    break :dsr_enum @Type(.{ .Enum = .{
        .tag_type = Tag.Backing,
        .fields = &fields,
        .decls = &.{},
        .is_exhaustive = true,
    } });
};

/// The tag type for our enum is a u16 but we use a packed struct
/// in order to pack the question bit into the tag. The "u16" size is
/// chosen somewhat arbitrarily to match the largest expected size
/// we see as a multiple of 8 bits.
pub const Tag = packed struct(u16) {
    pub const Backing = @typeInfo(@This()).Struct.backing_integer.?;
    value: u15,
    question: bool = false,

    test "order" {
        const t: Tag = .{ .value = 1 };
        const int: Backing = @bitCast(t);
        try std.testing.expectEqual(@as(Backing, 1), int);
    }
};

pub fn reqFromInt(v: u16, question: bool) ?Request {
    inline for (entries) |entry| {
        if (entry.value == v and entry.question == question) {
            const tag: Tag = .{ .question = question, .value = entry.value };
            const int: Tag.Backing = @bitCast(tag);
            return @enumFromInt(int);
        }
    }

    return null;
}

/// A single entry of a possible device status request we support. The
/// "question" field determines if it is valid with or without the "?"
/// prefix.
const Entry = struct {
    name: [:0]const u8,
    value: comptime_int,
    question: bool = false, // "?" request
};

/// The full list of device status request entries.
const entries: []const Entry = &.{
    .{ .name = "operating_status", .value = 5 },
    .{ .name = "cursor_position", .value = 6 },
    .{ .name = "color_scheme", .value = 996, .question = true },
};
