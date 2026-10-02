const std = @import("std");
const Config = @import("Config.zig");

/// Key is an enum of all the available configuration keys. This is used
/// when paired with diff to determine what fields have changed in a config,
/// amongst other things.
pub const Key = key: {
    const field_infos = @typeInfo(Config).@"struct".field_names;
    var names: [field_infos.len][]const u8 = undefined;
    var raw_values: [field_infos.len]comptime_int = undefined;
    var i: usize = 0;
    for (field_infos, &names, &raw_values) |field, *name, *raw| {
        // Ignore fields starting with "_" since they're internal and
        // not copied ever.
        if (field[0] == '_') continue;

        name.* = field;
        raw.* = i;
        i += 1;
    }

    const TagInt = std.math.IntFittingRange(0, field_infos.len - 1);
    var values: [i]TagInt = undefined;
    for (raw_values[0..i], &values) |raw, *val| {
        val.* = raw;
    }

    break :key @Enum(TagInt, .exhaustive, names[0..i], &values);
};

/// Returns the value type for a key
pub fn Value(comptime key: Key) type {
    const field_type = comptime field_type: {
        @setEvalBranchQuota(100_000);

        const fields = @typeInfo(Config).@"struct".field_names;
        for (fields) |field_name| {
            if (@field(Key, field_name) == key) {
                break :field_type @FieldType(Config, field_name);
            }
        }

        unreachable;
    };

    return field_type;
}

test "Value" {
    const testing = std.testing;

    try testing.expectEqual(Config.RepeatableString, Value(.@"font-family"));
    try testing.expectEqual(?bool, Value(.@"cursor-style-blink"));
}
