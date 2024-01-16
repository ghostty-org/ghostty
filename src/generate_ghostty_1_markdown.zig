const std = @import("std");
const Config = @import("config/Config.zig");
const Action = @import("cli/action.zig").Action;

const help_strings = @import("help_strings"){};
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena_alloc = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 2) {
        std.debug.print("invalid number of arguments provided!", .{});
        std.process.exit(1);
    }

    const path = args[1];

    var output = try std.fs.cwd().createFile(path, .{});
    defer output.close();

    const version_string = try std.fmt.allocPrint(alloc, "{}", .{build_options.version});

    const header_raw = @embedFile("doc/ghostty_1_header.md");
    const header = try alloc.alloc(u8, std.mem.replacementSize(u8, header_raw, "@@VERSION@@", version_string));
    _ = std.mem.replace(u8, header_raw, "@@VERSION@@", version_string, header);
    try output.writeAll(header);

    {
        try output.writeAll(
            \\# OPTIONS
            \\
            \\
        );
        const info = @typeInfo(Config);
        std.debug.assert(info == .Struct);

        inline for (info.Struct.fields) |field| {
            if (field.name[0] == '_') continue;

            try output.writeAll("`--");
            try output.writeAll(field.name);
            try output.writeAll("`\n\n");
            if (@hasField(@TypeOf(help_strings), field.name)) {
                var iter = std.mem.splitScalar(u8, @field(help_strings, field.name), '\n');
                var first = true;
                while (iter.next()) |s| {
                    try output.writeAll(if (first) ":   " else "    ");
                    try output.writeAll(s);
                    try output.writeAll("\n");
                    first = false;
                }
                try output.writeAll("\n\n");
            }
        }
    }

    {
        try output.writeAll(
            \\# ACTIONS
            \\
            \\
        );
        const info = @typeInfo(Action);
        std.debug.assert(info == .Enum);

        inline for (info.Enum.fields) |field| {
            if (field.name[0] == '_') continue;

            const action = std.meta.stringToEnum(Action, field.name).?;

            switch (action) {
                .help => try output.writeAll("`--help`\n\n"),
                .version => try output.writeAll("`--version`\n\n"),
                else => {
                    try output.writeAll("`+");
                    try output.writeAll(field.name);
                    try output.writeAll("`\n\n");
                },
            }

            if (@hasField(@TypeOf(help_strings), "+" ++ field.name)) {
                var iter = std.mem.splitScalar(u8, @field(help_strings, "+" ++ field.name), '\n');
                var first = true;
                while (iter.next()) |s| {
                    try output.writeAll(if (first) ":   " else "    ");
                    try output.writeAll(s);
                    try output.writeAll("\n");
                    first = false;
                }
                try output.writeAll("\n\n");
            }
        }
    }

    const footer_raw = @embedFile("doc/ghostty_1_footer.md");
    const footer = try alloc.alloc(u8, std.mem.replacementSize(u8, footer_raw, "@@VERSION@@", version_string));
    _ = std.mem.replace(u8, footer_raw, "@@VERSION@@", version_string, footer);
    try output.writeAll(footer);
}
