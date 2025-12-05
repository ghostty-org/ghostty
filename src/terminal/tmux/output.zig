const std = @import("std");
const testing = std.testing;

pub const ParseError = error{
    MissingEntry,
    ExtraEntry,
    FormatError,
};

/// Parse the output from a command with the given format struct
/// (returned usually by FormatStruct). The format struct is expected
/// to be in the order of the variables used in the format string and
/// the variables are expected to be plain variables (no conditionals,
/// extra formatting, etc.). Each variable is expected to be separated
/// by a single `delimiter` character.
pub fn parseFormatStruct(
    comptime T: type,
    str: []const u8,
    delimiter: u8,
) ParseError!T {
    // Parse all our fields
    const fields = @typeInfo(T).@"struct".fields;
    var it = std.mem.splitScalar(u8, str, delimiter);
    var result: T = undefined;
    inline for (fields) |field| {
        const part = it.next() orelse return error.MissingEntry;
        @field(result, field.name) = Variable.parse(
            @field(Variable, field.name),
            part,
        ) catch return error.FormatError;
    }

    // We should have consumed all parts now.
    if (it.next() != null) return error.ExtraEntry;

    return result;
}

/// Returns a struct type that contains fields for each of the given
/// format variables. This can be used with `parseFormatStruct` to
/// parse an output string into a format struct.
pub fn FormatStruct(comptime vars: []const Variable) type {
    var fields: [vars.len]std.builtin.Type.StructField = undefined;
    for (vars, &fields) |variable, *field| {
        field.* = .{
            .name = @tagName(variable),
            .type = variable.Type(),
            .default_value_ptr = null,
            .is_comptime = false,
            .alignment = @alignOf(variable.Type()),
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .auto,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

/// Possible variables in a tmux format string that we support.
///
/// Tmux supports a large number of variables, but we only implement
/// a subset of them here that are relevant to the use case of implementing
/// control mode for terminal emulators.
pub const Variable = enum {
    session_id,
    window_id,
    window_width,
    window_height,
    window_layout,

    /// Parse the given string value into the appropriate resulting
    /// type for this variable.
    pub fn parse(comptime self: Variable, value: []const u8) !Type(self) {
        return switch (self) {
            .session_id => if (value.len >= 2 and value[0] == '$')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_id => if (value.len >= 2 and value[0] == '@')
                try std.fmt.parseInt(usize, value[1..], 10)
            else
                return error.FormatError,
            .window_width => try std.fmt.parseInt(usize, value, 10),
            .window_height => try std.fmt.parseInt(usize, value, 10),
            .window_layout => value,
        };
    }

    /// The type of the parsed value for this variable type.
    pub fn Type(comptime self: Variable) type {
        return switch (self) {
            .session_id => usize,
            .window_id => usize,
            .window_width => usize,
            .window_height => usize,
            .window_layout => []const u8,
        };
    }
};

test "parse session id" {
    try testing.expectEqual(42, try Variable.parse(.session_id, "$42"));
    try testing.expectEqual(0, try Variable.parse(.session_id, "$0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "@0"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, "$"));
    try testing.expectError(error.FormatError, Variable.parse(.session_id, ""));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.session_id, "$abc"));
}

test "parse window id" {
    try testing.expectEqual(42, try Variable.parse(.window_id, "@42"));
    try testing.expectEqual(0, try Variable.parse(.window_id, "@0"));
    try testing.expectEqual(12345, try Variable.parse(.window_id, "@12345"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "0"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "$0"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, "@"));
    try testing.expectError(error.FormatError, Variable.parse(.window_id, ""));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_id, "@abc"));
}

test "parse window width" {
    try testing.expectEqual(80, try Variable.parse(.window_width, "80"));
    try testing.expectEqual(0, try Variable.parse(.window_width, "0"));
    try testing.expectEqual(12345, try Variable.parse(.window_width, "12345"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_width, "abc"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_width, "80px"));
    try testing.expectError(error.Overflow, Variable.parse(.window_width, "-1"));
}

test "parse window height" {
    try testing.expectEqual(24, try Variable.parse(.window_height, "24"));
    try testing.expectEqual(0, try Variable.parse(.window_height, "0"));
    try testing.expectEqual(12345, try Variable.parse(.window_height, "12345"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_height, "abc"));
    try testing.expectError(error.InvalidCharacter, Variable.parse(.window_height, "24px"));
    try testing.expectError(error.Overflow, Variable.parse(.window_height, "-1"));
}

test "parse window layout" {
    try testing.expectEqualStrings("abc123", try Variable.parse(.window_layout, "abc123"));
    try testing.expectEqualStrings("", try Variable.parse(.window_layout, ""));
    try testing.expectEqualStrings("a]b,c{d}e(f)", try Variable.parse(.window_layout, "a]b,c{d}e(f)"));
}

test "parseFormatStruct single field" {
    const T = FormatStruct(&.{.session_id});
    const result = try parseFormatStruct(T, "$42", ' ');
    try testing.expectEqual(42, result.session_id);
}

test "parseFormatStruct multiple fields" {
    const T = FormatStruct(&.{ .session_id, .window_id, .window_width, .window_height });
    const result = try parseFormatStruct(T, "$1 @2 80 24", ' ');
    try testing.expectEqual(1, result.session_id);
    try testing.expectEqual(2, result.window_id);
    try testing.expectEqual(80, result.window_width);
    try testing.expectEqual(24, result.window_height);
}

test "parseFormatStruct with string field" {
    const T = FormatStruct(&.{ .window_id, .window_layout });
    const result = try parseFormatStruct(T, "@5,abc123", ',');
    try testing.expectEqual(5, result.window_id);
    try testing.expectEqualStrings("abc123", result.window_layout);
}

test "parseFormatStruct different delimiter" {
    const T = FormatStruct(&.{ .window_width, .window_height });
    const result = try parseFormatStruct(T, "120\t40", '\t');
    try testing.expectEqual(120, result.window_width);
    try testing.expectEqual(40, result.window_height);
}

test "parseFormatStruct missing entry" {
    const T = FormatStruct(&.{ .session_id, .window_id });
    try testing.expectError(error.MissingEntry, parseFormatStruct(T, "$1", ' '));
}

test "parseFormatStruct extra entry" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.ExtraEntry, parseFormatStruct(T, "$1 @2", ' '));
}

test "parseFormatStruct format error" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.FormatError, parseFormatStruct(T, "42", ' '));
    try testing.expectError(error.FormatError, parseFormatStruct(T, "@42", ' '));
    try testing.expectError(error.FormatError, parseFormatStruct(T, "$abc", ' '));
}

test "parseFormatStruct empty string" {
    const T = FormatStruct(&.{.session_id});
    try testing.expectError(error.FormatError, parseFormatStruct(T, "", ' '));
}

test "parseFormatStruct with empty layout field" {
    const T = FormatStruct(&.{ .session_id, .window_layout });
    const result = try parseFormatStruct(T, "$1,", ',');
    try testing.expectEqual(1, result.session_id);
    try testing.expectEqualStrings("", result.window_layout);
}
