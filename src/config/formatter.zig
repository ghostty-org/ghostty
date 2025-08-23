const formatter = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;

/// Returns a single entry formatter for the given field name and writer.
pub fn entryFormatter(
    name: []const u8,
    writer: anytype,
) EntryFormatter(@TypeOf(writer)) {
    return .{ .name = name, .writer = writer };
}

/// The entry formatter type for a given writer.
pub fn EntryFormatter(comptime WriterType: type) type {
    return struct {
        name: []const u8,
        writer: WriterType,

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
}

/// Format a single type with the given name and value.
pub fn formatEntry(
    comptime T: type,
    name: []const u8,
    value: T,
    writer: anytype,
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
            try writer.print("{s} = {s}\n", .{ name, @tagName(value) });
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

/// FileFormatter is a formatter implementation that outputs the
/// config in a file-like format. This uses more generous whitespace,
/// can include comments, etc.
pub const FileFormatter = struct {
    alloc: Allocator,
    config: *const Config,

    /// Include comments for documentation of each key
    docs: bool = false,

    /// Only include changed values from the default.
    changed: bool = false,

    /// Implements std.fmt so it can be used directly with std.fmt.
    pub fn format(
        self: FileFormatter,
        comptime layout: []const u8,
        opts: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        @setEvalBranchQuota(10_000);

        _ = layout;
        _ = opts;

        // If we're change-tracking then we need the default config to
        // compare against.
        var default: ?Config = if (self.changed)
            try .default(self.alloc)
        else
            null;
        defer if (default) |*v| v.deinit();

        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (field.name[0] == '_') continue;

            const value = @field(self.config, field.name);
            const do_format = if (default) |d| format: {
                const key = @field(Key, field.name);
                break :format d.changed(self.config, key);
            } else true;

            if (do_format) {
                const do_docs = self.docs and @hasDecl(help_strings.Config, field.name);
                if (do_docs) {
                    const help = @field(help_strings.Config, field.name);
                    var lines = std.mem.splitScalar(u8, help, '\n');
                    while (lines.next()) |line| {
                        try writer.print("# {s}\n", .{line});
                    }
                }

                try formatEntry(
                    field.type,
                    field.name,
                    value,
                    writer,
                );

                if (do_docs) try writer.print("\n", .{});
            }
        }
    }
};

test "format default config" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
    };
    try std.fmt.format(buf.writer(), "{}", .{fmt});

    //std.log.warn("{s}", .{buf.items});
}

test "format default config changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"font-size" = 42;

    var buf = std.ArrayList(u8).init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
        .changed = true,
    };
    try std.fmt.format(buf.writer(), "{}", .{fmt});

    //std.log.warn("{s}", .{buf.items});
}

test "formatEntry bool" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", true, buf.writer());
        try testing.expectEqualStrings("a = true\n", buf.items);
    }

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", false, buf.writer());
        try testing.expectEqualStrings("a = false\n", buf.items);
    }
}

test "formatEntry int" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(u8, "a", 123, buf.writer());
        try testing.expectEqualStrings("a = 123\n", buf.items);
    }
}

test "formatEntry float" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(f64, "a", 0.7, buf.writer());
        try testing.expectEqualStrings("a = 0.7\n", buf.items);
    }
}

test "formatEntry enum" {
    const testing = std.testing;
    const Enum = enum { one, two, three };

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(Enum, "a", .two, buf.writer());
        try testing.expectEqualStrings("a = two\n", buf.items);
    }
}

test "formatEntry void" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(void, "a", {}, buf.writer());
        try testing.expectEqualStrings("a = \n", buf.items);
    }
}

test "formatEntry optional" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", null, buf.writer());
        try testing.expectEqualStrings("a = \n", buf.items);
    }

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", false, buf.writer());
        try testing.expectEqualStrings("a = false\n", buf.items);
    }
}

test "formatEntry string" {
    const testing = std.testing;

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry([]const u8, "a", "hello", buf.writer());
        try testing.expectEqualStrings("a = hello\n", buf.items);
    }
}

test "formatEntry packed struct" {
    const testing = std.testing;
    const Value = packed struct {
        one: bool = true,
        two: bool = false,
    };

    {
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();
        try formatEntry(Value, "a", .{}, buf.writer());
        try testing.expectEqualStrings("a = one,no-two\n", buf.items);
    }
}
