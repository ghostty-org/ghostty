const std = @import("std");
const help_strings = @import("help_strings");
const build_config = @import("../../build_config.zig");
const Config = @import("../../config/Config.zig");
const Action = @import("../../cli/ghostty.zig").Action;
const KeybindAction = @import("../../input/Binding.zig").Action;

pub fn substitute(alloc: std.mem.Allocator, input: []const u8, writer: *std.Io.Writer) !void {
    const output = try alloc.alloc(u8, std.mem.replacementSize(
        u8,
        input,
        "@@VERSION@@",
        build_config.version_string,
    ));
    defer alloc.free(output);

    _ = std.mem.replace(u8, input, "@@VERSION@@", build_config.version_string, output);
    try writer.writeAll(output);
}

pub fn genConfig(writer: *std.Io.Writer, cli: bool) !void {
    try writer.writeAll(
        \\
        \\# CONFIGURATION OPTIONS
        \\
        \\
    );

    @setEvalBranchQuota(5000);
    inline for (@typeInfo(Config).@"struct".field_names) |field| {
        if (field[0] == '_') continue;

        try writer.writeAll("**`");
        if (cli) try writer.writeAll("--");
        try writer.writeAll(field);
        try writer.writeAll("`**\n\n");
        if (@hasDecl(help_strings.Config, field)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.Config, field), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(if (first) ":   " else "    ");
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n\n");
        }
    }
}

pub fn genActions(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\
        \\# COMMAND LINE ACTIONS
        \\
        \\
    );

    inline for (@typeInfo(Action).@"enum".field_names) |field| {
        const action = std.meta.stringToEnum(Action, field).?;

        switch (action) {
            .help => try writer.writeAll("**`--help`**\n\n"),
            .version => try writer.writeAll("**`--version`**\n\n"),
            else => {
                try writer.writeAll("**`+");
                try writer.writeAll(field);
                try writer.writeAll("`**\n\n");
            },
        }

        if (@hasDecl(help_strings.Action, field)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.Action, field), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(if (first) ":   " else "    ");
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n\n");
        }
    }
}

pub fn genKeybindActions(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\
        \\# KEYBIND ACTIONS
        \\
        \\
    );

    const info = @typeInfo(KeybindAction);
    std.debug.assert(info == .@"union");

    @setEvalBranchQuota(5000);
    inline for (info.@"union".field_names) |field| {
        if (field[0] == '_') continue;

        try writer.writeAll("**`");
        try writer.writeAll(field);
        try writer.writeAll("`**\n\n");

        if (@hasDecl(help_strings.KeybindAction, field)) {
            var iter = std.mem.splitScalar(u8, @field(help_strings.KeybindAction, field), '\n');
            var first = true;
            while (iter.next()) |s| {
                try writer.writeAll(if (first) ":   " else "    ");
                try writer.writeAll(s);
                try writer.writeAll("\n");
                first = false;
            }
            try writer.writeAll("\n\n");
        }
    }
}
