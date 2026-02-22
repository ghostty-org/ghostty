const std = @import("std");
const Allocator = std.mem.Allocator;
const cli = @import("../cli.zig");
const formatterpkg = @import("formatter.zig");

/// Shell integration values
pub const ShellIntegration = enum {
    none,
    detect,
    bash,
    elvish,
    fish,
    nushell,
    zsh,
};

/// Shell integration features
pub const ShellIntegrationFeatures = struct {
    pub const Cursor = struct {
        shape: Shape = .bar,
        style: Style = .default,

        pub const Shape = enum {
            disabled,
            bar,
            block,
            underline,
        };

        pub const Style = enum {
            default, // cursor-style-blink
            blink,
            steady,
        };
    };

    cursor: Cursor = .{},
    path: bool = true,
    @"ssh-env": bool = false,
    @"ssh-terminfo": bool = false,
    sudo: bool = false,
    title: bool = true,

    pub fn parseCLI(input: ?[]const u8) !ShellIntegrationFeatures {
        const v = input orelse return error.ValueRequired;
        var result: ShellIntegrationFeatures = .{};

        // Handle "true" or "false" to toggle all features
        if (std.mem.eql(u8, v, "true") or std.mem.eql(u8, v, "false")) {
            const b = std.mem.eql(u8, v, "true");
            result.cursor = if (b) .{} else .{ .shape = .disabled };
            inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
                if (field.type == bool) {
                    @field(result, field.name) = b;
                }
            }
            return result;
        }

        var iter = std.mem.splitSequence(u8, v, ",");
        loop: while (iter.next()) |part_raw| {
            const trimmed = std.mem.trim(u8, part_raw, cli.args.whitespace);

            // Handle cursor[:shape[:style]] syntax
            if (std.mem.startsWith(u8, trimmed, "cursor")) {
                var cursor_iter = std.mem.splitScalar(u8, trimmed, ':');
                _ = cursor_iter.next(); // skip "cursor"

                // Parse shape (if present)
                if (cursor_iter.next()) |shape| {
                    // For convenience, "blink" or "steady" alone implies bar (default)
                    if (std.mem.eql(u8, shape, "blink")) {
                        result.cursor.shape = .bar;
                        result.cursor.style = .blink;
                    } else if (std.mem.eql(u8, shape, "steady")) {
                        result.cursor.shape = .bar;
                        result.cursor.style = .steady;
                    } else {
                        result.cursor.shape = std.meta.stringToEnum(Cursor.Shape, shape) orelse return error.InvalidValue;
                    }

                    // Parse style (if present)
                    if (cursor_iter.next()) |style| {
                        result.cursor.style = std.meta.stringToEnum(Cursor.Style, style) orelse return error.InvalidValue;
                    }
                } else {
                    result.cursor = .{};
                }
                continue;
            } else if (std.mem.eql(u8, trimmed, "no-cursor")) {
                result.cursor.shape = .disabled;
                continue;
            }

            const name, const value = part: {
                const negation_prefix = "no-";
                const trimmed_name = std.mem.trim(u8, part_raw, cli.args.whitespace);
                if (std.mem.startsWith(u8, trimmed, negation_prefix)) {
                    break :part .{ trimmed_name[negation_prefix.len..], false };
                } else {
                    break :part .{ trimmed_name, true };
                }
            };

            inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
                if (field.type == bool and std.mem.eql(u8, field.name, name)) {
                    @field(result, field.name) = value;
                    continue :loop;
                }
            }

            // No field matched
            return error.InvalidValue;
        }

        return result;
    }

    pub const FormatMode = enum {
        /// Human-readable format for config output (e.g., "cursor:block:blink")
        config,
        /// Format for GHOSTTY_SHELL_FEATURES environment variable (e.g., "cursor:5")
        env,
    };

    pub fn format(self: ShellIntegrationFeatures, writer: *std.Io.Writer, mode: FormatMode) anyerror!void {
        const fields = comptime fields: {
            const all_fields = @typeInfo(ShellIntegrationFeatures).@"struct".fields;
            var sorted: [all_fields.len]std.builtin.Type.StructField = all_fields[0..].*;
            const SortContext = struct {
                fn lessThan(_: @This(), a: std.builtin.Type.StructField, b: std.builtin.Type.StructField) bool {
                    return std.ascii.orderIgnoreCase(a.name, b.name) == .lt;
                }
            };
            std.mem.sortUnstable(std.builtin.Type.StructField, &sorted, SortContext{}, SortContext.lessThan);
            break :fields sorted;
        };

        inline for (fields) |field| {
            const enabled = switch (field.type) {
                bool => @field(self, field.name),
                Cursor => @field(self, field.name).shape != .disabled,
                else => @compileError("unexpected field type in ShellIntegrationFeatures"),
            };
            if (enabled) {
                if (writer.end > 0) try writer.writeByte(',');
                try writer.writeAll(field.name);
                switch (field.type) {
                    Cursor => {
                        const cursor = @field(self, field.name);
                        switch (mode) {
                            // DECSCUSR codes
                            .env => {
                                const decscusr: u8 = switch (cursor.shape) {
                                    .disabled => unreachable,
                                    .bar => switch (cursor.style) {
                                        .default => unreachable,
                                        .blink => 5,
                                        .steady => 6,
                                    },
                                    .block => switch (cursor.style) {
                                        .default => unreachable,
                                        .blink => 1,
                                        .steady => 2,
                                    },
                                    .underline => switch (cursor.style) {
                                        .default => unreachable,
                                        .blink => 3,
                                        .steady => 4,
                                    },
                                };
                                try writer.print(":{d}", .{decscusr});
                            },
                            // enum tag names
                            .config => {
                                try writer.writeByte(':');
                                try writer.writeAll(@tagName(cursor.shape));
                                if (cursor.style != .default) {
                                    try writer.writeByte(':');
                                    try writer.writeAll(@tagName(cursor.style));
                                }
                            },
                        }
                    },
                    else => {},
                }
            }
        }
    }

    pub fn formatEntry(self: ShellIntegrationFeatures, formatter: formatterpkg.EntryFormatter) !void {
        var buf: [128]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        try self.format(&writer, .config);
        try formatter.formatEntry([]const u8, buf[0..writer.end]);
    }

    pub fn clone(self: ShellIntegrationFeatures, _: Allocator) error{}!ShellIntegrationFeatures {
        return self;
    }

    pub fn equal(self: ShellIntegrationFeatures, other: ShellIntegrationFeatures) bool {
        return std.meta.eql(self, other);
    }

    test "parseCLI" {
        const testing = std.testing;

        // Test that we can parse each bool field by name.
        inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
            if (comptime field.type == bool) {
                const result = try ShellIntegrationFeatures.parseCLI(field.name);
                try testing.expect(@field(result, field.name));
            }
        }

        // Test that we can parse each bool field with "no-" prefix.
        inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
            if (comptime field.type == bool) {
                const result = try ShellIntegrationFeatures.parseCLI("no-" ++ field.name);
                try testing.expect(!@field(result, field.name));
            }
        }

        // Test "true" enables all features
        {
            const result = try ShellIntegrationFeatures.parseCLI("true");
            inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
                switch (field.type) {
                    bool => try testing.expect(@field(result, field.name)),
                    Cursor => {
                        try testing.expectEqual(Cursor.Shape.bar, @field(result, field.name).shape);
                        try testing.expectEqual(Cursor.Style.default, @field(result, field.name).style);
                    },
                    else => {},
                }
            }
        }

        // Test "false" disables all features
        {
            const result = try ShellIntegrationFeatures.parseCLI("false");
            inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
                switch (field.type) {
                    bool => try testing.expect(!@field(result, field.name)),
                    Cursor => try testing.expectEqual(Cursor.Shape.disabled, @field(result, field.name).shape),
                    else => {},
                }
            }
        }

        // Test all comma-separated field names.
        const all_input = comptime blk: {
            const fields = @typeInfo(ShellIntegrationFeatures).@"struct".fields;
            var buf: []const u8 = fields[0].name;
            for (fields[1..]) |field| buf = buf ++ "," ++ field.name;
            break :blk buf;
        };
        const all_features = try ShellIntegrationFeatures.parseCLI(all_input);
        inline for (@typeInfo(ShellIntegrationFeatures).@"struct".fields) |field| {
            const value = @field(all_features, field.name);
            switch (field.type) {
                bool => try testing.expect(value),
                Cursor => {
                    try testing.expectEqual(Cursor.Shape.bar, value.shape);
                    try testing.expectEqual(Cursor.Style.default, value.style);
                },
                else => @compileError("unexpected field type in ShellIntegrationFeatures"),
            }
        }

        // Cursor shapes and styles
        inline for (@typeInfo(Cursor.Shape).@"enum".fields) |shape_field| {
            const shape = @field(Cursor.Shape, shape_field.name);
            if (comptime shape != .disabled) {
                inline for (@typeInfo(Cursor.Style).@"enum".fields) |style_field| {
                    const style = @field(Cursor.Style, style_field.name);
                    const style_name = if (comptime style == .default) "" else ":" ++ style_field.name;
                    const input = "cursor:" ++ shape_field.name ++ style_name;
                    const result = try ShellIntegrationFeatures.parseCLI(input);
                    try testing.expectEqual(shape, result.cursor.shape);
                    try testing.expectEqual(style, result.cursor.style);
                }
            }
        }
        {
            const result = try ShellIntegrationFeatures.parseCLI("cursor:blink");
            try testing.expectEqual(Cursor.Shape.bar, result.cursor.shape);
            try testing.expectEqual(Cursor.Style.blink, result.cursor.style);
        }
        {
            const result = try ShellIntegrationFeatures.parseCLI("cursor:steady");
            try testing.expectEqual(Cursor.Shape.bar, result.cursor.shape);
            try testing.expectEqual(Cursor.Style.steady, result.cursor.style);
        }
    }

    test "format" {
        const testing = std.testing;

        const testFormat = struct {
            fn f(features: ShellIntegrationFeatures, mode: FormatMode, expected: []const u8) !void {
                var buf: [128]u8 = undefined;
                var writer: std.Io.Writer = .fixed(&buf);
                try features.format(&writer, mode);
                try testing.expectEqualStrings(expected, buf[0..writer.end]);
            }
        }.f;

        // .config format
        try testFormat(.{ .cursor = .{ .shape = .bar, .style = .steady }, .title = true }, .config, "cursor:bar:steady,path,title");
        try testFormat(.{ .cursor = .{ .shape = .bar, .style = .blink }, .sudo = true }, .config, "cursor:bar:blink,path,sudo,title");
        try testFormat(.{ .cursor = .{ .shape = .disabled }, .title = true }, .config, "path,title");
        try testFormat(.{ .cursor = .{ .shape = .block, .style = .blink }, .title = true }, .config, "cursor:block:blink,path,title");
        try testFormat(.{ .cursor = .{ .shape = .underline, .style = .default } }, .config, "cursor:underline,path,title");
        try testFormat(.{ .cursor = .{ .shape = .bar, .style = .default } }, .config, "cursor:bar,path,title");

        // .env format
        try testFormat(.{ .cursor = .{ .shape = .bar, .style = .steady }, .title = true }, .env, "cursor:6,path,title");
        try testFormat(.{ .cursor = .{ .shape = .bar, .style = .blink }, .sudo = true }, .env, "cursor:5,path,sudo,title");
        try testFormat(.{ .cursor = .{ .shape = .disabled }, .title = true }, .env, "path,title");
        try testFormat(.{ .cursor = .{ .shape = .block, .style = .blink }, .title = true }, .env, "cursor:1,path,title");
        try testFormat(.{ .cursor = .{ .shape = .underline, .style = .steady } }, .env, "cursor:4,path,title");
    }
};
