const std = @import("std");
const Config = @import("config/Config.zig");
const help_strings = @import("help_strings"){};
const build_options = @import("build_options");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena_alloc = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_alloc.deinit();
    const alloc = arena_alloc.allocator();

    // const gen: help_strings = .{};

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

    const header = @embedFile("doc/ghostty_5_header.md");
    const headerx = try alloc.alloc(u8, std.mem.replacementSize(u8, header, "@@VERSION@@", version_string));
    _ = std.mem.replace(u8, header, "@@VERSION@@", version_string, headerx);
    try output.writeAll(headerx);

    const info = @typeInfo(Config);
    std.debug.assert(info == .Struct);

    inline for (info.Struct.fields) |field| {
        if (field.name[0] == '_') continue;

        try output.writeAll("`");
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

    const footer = @embedFile("doc/ghostty_5_footer.md");
    const footerx = try alloc.alloc(u8, std.mem.replacementSize(u8, footer, "@@VERSION@@", version_string));
    _ = std.mem.replace(u8, footer, "@@VERSION@@", version_string, footerx);
    try output.writeAll(footerx);
}
