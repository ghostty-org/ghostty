const formatter = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Key = @import("key.zig").Key;

/// Returns a single entry formatter for the given field name and writer.
pub fn entryFormatter(
    name: []const u8,
    writer: *std.Io.Writer,
) EntryFormatter {
    return .{ .name = name, .writer = writer };
}

/// The entry formatter type for a given writer.
pub const EntryFormatter = struct {
    name: []const u8,
    writer: *std.Io.Writer,

    pub fn formatEntry(
        self: @This(),
        comptime T: type,
        value: T,
    ) !void {
        return formatter.formatEntry(
            T,
            self.name,
            value,
            self.writer,
        );
    }
};

/// Format a single type with the given name and value.
pub fn formatEntry(
    comptime T: type,
    name: []const u8,
    value: T,
    writer: *std.Io.Writer,
) !void {
    switch (@typeInfo(T)) {
        .bool, .int => {
            try writer.print("{s} = {}\n", .{ name, value });
            return;
        },

        .float => {
            try writer.print("{s} = {d}\n", .{ name, value });
            return;
        },

        .@"enum" => {
            try writer.print("{s} = {t}\n", .{ name, value });
            return;
        },

        .void => {
            try writer.print("{s} = \n", .{name});
            return;
        },

        .optional => |info| {
            if (value) |inner| {
                try formatEntry(
                    info.child,
                    name,
                    inner,
                    writer,
                );
            } else {
                try writer.print("{s} = \n", .{name});
            }

            return;
        },

        .pointer => switch (T) {
            []const u8,
            [:0]const u8,
            => {
                try writer.print("{s} = {s}\n", .{ name, value });
                return;
            },

            else => {},
        },

        // Structs of all types require a "formatEntry" function
        // to be defined which will be called to format the value.
        // This is given the formatter in use so that they can
        // call BACK to our formatEntry to write each primitive
        // value.
        .@"struct" => |info| if (@hasDecl(T, "formatEntry")) {
            try value.formatEntry(entryFormatter(name, writer));
            return;
        } else switch (info.layout) {
            // Packed structs we special case.
            .@"packed" => {
                try writer.print("{s} = ", .{name});
                inline for (info.fields, 0..) |field, i| {
                    if (i > 0) try writer.print(",", .{});
                    try writer.print("{s}{s}", .{
                        if (!@field(value, field.name)) "no-" else "",
                        field.name,
                    });
                }
                try writer.print("\n", .{});
                return;
            },

            else => {},
        },

        .@"union" => if (@hasDecl(T, "formatEntry")) {
            try value.formatEntry(entryFormatter(name, writer));
            return;
        },

        else => {},
    }

    // Compile error so that we can catch missing cases.
    @compileLog(T);
    @compileError("missing case for type");
}

test "formatEntry bool" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", true, &buf.writer);
        try testing.expectEqualStrings("a = true\n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry int" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(u8, "a", 123, &buf.writer);
        try testing.expectEqualStrings("a = 123\n", buf.written());
    }
}

test "formatEntry float" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(f64, "a", 0.7, &buf.writer);
        try testing.expectEqualStrings("a = 0.7\n", buf.written());
    }
}

test "formatEntry enum" {
    const testing = std.testing;
    const Enum = enum { one, two, three };

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(Enum, "a", .two, &buf.writer);
        try testing.expectEqualStrings("a = two\n", buf.written());
    }
}

test "formatEntry void" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(void, "a", {}, &buf.writer);
        try testing.expectEqualStrings("a = \n", buf.written());
    }
}

test "formatEntry optional" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", null, &buf.writer);
        try testing.expectEqualStrings("a = \n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry string" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry([]const u8, "a", "hello", &buf.writer);
        try testing.expectEqualStrings("a = hello\n", buf.written());
    }
}

test "formatEntry packed struct" {
    const testing = std.testing;
    const Value = packed struct {
        one: bool = true,
        two: bool = false,
    };

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(Value, "a", .{}, &buf.writer);
        try testing.expectEqualStrings("a = one,no-two\n", buf.written());
    }
}
