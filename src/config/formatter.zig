const formatter = @This();
const std = @import("std");
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");
const Config = @import("Config.zig");
const Key = @import("key.zig").Key;

/// Returns a single entry formatter for the given field name and writer.
pub fn entryFormatter(
    name: []const u8,
    writer: *std.Io.Writer,
    links: bool,
) EntryFormatter {
    return .{
        .name = name,
        .writer = writer,
        .links = links,
    };
}

/// The entry formatter type for a given writer.
pub const EntryFormatter = struct {
    name: []const u8,
    writer: *std.Io.Writer,
    links: bool,

    pub fn formatEntry(
        self: @This(),
        comptime T: type,
        value: T,
    ) !void {
        return formatter.formatEntry(
            T,
            self.name,
            value,
            self.links,
            self.writer,
        );
    }
};

/// Format a single type with the given name and value.
pub fn formatEntry(
    comptime T: type,
    name: []const u8,
    value: T,
    links: bool,
    writer: *std.Io.Writer,
) !void {
    var linkstart_buf: [128]u8 = undefined;
    var linkend_buf: [16]u8 = undefined;

    const linkstart, const linkend = l: {
        if (!links) break :l .{ "", "" };
        const linkstart = std.fmt.bufPrint(
            &linkstart_buf,
            "\x1b]8;;https://ghostty.org/docs/config/reference#{s}\x1b\\",
            .{name},
        ) catch break :l .{ "", "" };
        const linkend = std.fmt.bufPrint(
            &linkend_buf,
            "\x1b]8;;\x1b\\",
            .{},
        ) catch break :l .{ "", "" };
        break :l .{ linkstart, linkend };
    };

    switch (@typeInfo(T)) {
        .bool, .int => {
            try writer.print("{s}{s}{s} = {}\n", .{ linkstart, name, linkend, value });
            return;
        },

        .float => {
            try writer.print("{s}{s}{s} = {d}\n", .{ linkstart, name, linkend, value });
            return;
        },

        .@"enum" => {
            try writer.print("{s}{s}{s} = {t}\n", .{ linkstart, name, linkend, value });
            return;
        },

        .void => {
            try writer.print("{s}{s}{s} = \n", .{ linkstart, name, linkend });
            return;
        },

        .optional => |info| {
            if (value) |inner| {
                try formatEntry(
                    info.child,
                    name,
                    inner,
                    links,
                    writer,
                );
            } else {
                try writer.print("{s}{s}{s} = \n", .{ linkstart, name, linkend });
            }

            return;
        },

        .pointer => switch (T) {
            []const u8,
            [:0]const u8,
            => {
                try writer.print("{s}{s}{s} = {s}\n", .{ linkstart, name, linkend, value });
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
            try value.formatEntry(entryFormatter(name, writer, links));
            return;
        } else switch (info.layout) {
            // Packed structs we special case.
            .@"packed" => {
                try writer.print("{s}{s}{s} = ", .{ linkstart, name, linkend });
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
            try value.formatEntry(entryFormatter(name, writer, links));
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

    /// Use OSC 8 to link to the online documentation.
    links: bool = false,

    /// Implements std.fmt so it can be used directly with std.fmt.
    pub fn format(
        self: FileFormatter,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        @setEvalBranchQuota(10_000);

        // If we're change-tracking then we need the default config to
        // compare against.
        var default: ?Config = if (self.changed)
            Config.default(self.alloc) catch return error.WriteFailed
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

                formatEntry(
                    field.type,
                    field.name,
                    value,
                    self.links,
                    writer,
                ) catch return error.WriteFailed;

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

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}

test "format default config changed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var cfg = try Config.default(alloc);
    defer cfg.deinit();
    cfg.@"font-size" = 42;

    var buf: std.Io.Writer.Allocating = .init(alloc);
    defer buf.deinit();

    // We just make sure this works without errors. We aren't asserting output.
    const fmt: FileFormatter = .{
        .alloc = alloc,
        .config = &cfg,
        .changed = true,
    };
    try fmt.format(&buf.writer);

    //std.log.warn("{s}", .{buf.written()});
}

test "formatEntry bool" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", true, false, &buf.writer);
        try testing.expectEqualStrings("a = true\n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(bool, "a", false, false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry int" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(u8, "a", 123, false, &buf.writer);
        try testing.expectEqualStrings("a = 123\n", buf.written());
    }
}

test "formatEntry float" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(f64, "a", 0.7, false, &buf.writer);
        try testing.expectEqualStrings("a = 0.7\n", buf.written());
    }
}

test "formatEntry enum" {
    const testing = std.testing;
    const Enum = enum { one, two, three };

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(Enum, "a", .two, false, &buf.writer);
        try testing.expectEqualStrings("a = two\n", buf.written());
    }
}

test "formatEntry void" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(void, "a", {}, false, &buf.writer);
        try testing.expectEqualStrings("a = \n", buf.written());
    }
}

test "formatEntry optional" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", null, false, &buf.writer);
        try testing.expectEqualStrings("a = \n", buf.written());
    }

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(?bool, "a", false, false, &buf.writer);
        try testing.expectEqualStrings("a = false\n", buf.written());
    }
}

test "formatEntry string" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry([]const u8, "a", "hello", false, &buf.writer);
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
        try formatEntry(Value, "a", .{}, false, &buf.writer);
        try testing.expectEqualStrings("a = one,no-two\n", buf.written());
    }
}

test "formatEntry links" {
    const testing = std.testing;

    {
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();
        try formatEntry(void, "a", {}, true, &buf.writer);
        try testing.expectEqualStrings("\x1b]8;;https://ghostty.org/docs/config/reference#a\x1b\\a\x1b]8;;\x1b\\ = \n", buf.written());
    }
}
