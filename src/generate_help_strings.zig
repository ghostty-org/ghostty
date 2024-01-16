const std = @import("std");
const ziglyph = @import("ziglyph");
const Action = @import("cli/action.zig").Action;
const Config = @import("config/Config.zig");

pub fn searchConfigAst(alloc: std.mem.Allocator, output: std.fs.File) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("config/Config.zig"), .zig);
    defer ast.deinit(alloc);

    const config: Config = .{};

    const tokens = ast.tokens.items(.tag);

    var set = std.StringHashMap(bool).init(alloc);
    defer set.deinit();

    try output.writeAll(
        \\//THIS FILE IS AUTO GENERATED
        \\//DO NOT MAKE ANY CHANGES TO THIS FILE!
    );

    try output.writeAll("\n\n");

    inline for (@typeInfo(@TypeOf(config)).Struct.fields) |field| {
        if (field.name[0] != '_') try set.put(field.name, false);
    }

    var index: u32 = 0;
    while (true) : (index += 1) {
        if (index >= tokens.len) break;
        const token = tokens[index];

        if (token == .identifier) {
            const slice = ast.tokenSlice(index);
            // We need this check because the ast grabs the identifier with @"" in case it's used.
            const key = if (slice[0] == '@') slice[2 .. slice.len - 1] else slice;

            if (key[0] == '_') continue;

            if (set.get(key)) |value| {
                if (value) continue;
                if (tokens[index - 1] != .doc_comment) continue;

                const comment = try consumeDocComments(alloc, ast, index - 1, &tokens);
                const prop_type = ": " ++ "[:0]const u8 " ++ "= " ++ "\n";

                try output.writeAll(slice);
                try output.writeAll(prop_type);
                // const concat = try std.mem.concat(self.alloc, u8, &.{ slice, prop_type });
                // try output.writeAll(concat);
                try output.writeAll(comment);
                try output.writeAll("\n\n");

                try set.put(key, true);
            }
        }
        if (token == .eof) break;
    }
}

fn actionPath(comptime action: Action) []const u8 {
    return switch (action) {
        .version => "cli/version.zig",
        .@"list-fonts" => "cli/list_fonts.zig",
        .@"list-keybinds" => "cli/list_keybinds.zig",
        .@"list-themes" => "cli/list_themes.zig",
        .@"list-colors" => "cli/list_colors.zig",
    };
}

pub fn searchActionsAst(alloc: std.mem.Allocator, output: std.fs.File) !void {
    inline for (@typeInfo(Action).Enum.fields) |field| {
        const action = comptime std.meta.stringToEnum(Action, field.name).?;

        var ast = try std.zig.Ast.parse(alloc, @embedFile(comptime actionPath(action)), .zig);
        const tokens = ast.tokens.items(.tag);

        var index: u32 = 0;
        while (true) : (index += 1) {
            if (tokens[index] == .keyword_fn) {
                if (std.mem.eql(u8, ast.tokenSlice(index + 1), "run")) {
                    if (tokens[index - 2] != .doc_comment) {
                        std.debug.print("doc comment must be present on run function of the {s} action!", .{field.name});
                        std.process.exit(1);
                    }
                    const comment = try consumeDocComments(alloc, ast, index - 2, &tokens);
                    const prop_type = "@\"+" ++ field.name ++ "\"" ++ ": " ++ "[:0]const u8 " ++ "= " ++ "\n";

                    try output.writeAll(prop_type);
                    try output.writeAll(comment);
                    try output.writeAll("\n\n");
                    break;
                }
            }
        }
    }
}

fn consumeDocComments(alloc: std.mem.Allocator, ast: std.zig.Ast, index: std.zig.Ast.TokenIndex, toks: anytype) ![]const u8 {
    var lines = std.ArrayList([]const u8).init(alloc);
    defer lines.deinit();

    const tokens = toks.*;
    var current_idx = index;

    // We iterate backwards because the doc_comment tokens should be on top of each other in case there are any.
    while (true) : (current_idx -= 1) {
        const token = tokens[current_idx];

        if (token != .doc_comment) break;
        // Insert at 0 so that we don't have the text in reverse.
        try lines.insert(0, ast.tokenSlice(current_idx)[3..]);
    }

    const prefix = findCommonPrefix(lines);

    var buffer = std.ArrayList(u8).init(alloc);
    const writer = buffer.writer();

    for (lines.items) |line| {
        try writer.writeAll("    \\\\");
        try writer.writeAll(line[@min(prefix, line.len)..]);
        try writer.writeAll("\n");
    }
    try writer.writeAll(",\n");

    return buffer.toOwnedSlice();
}

fn findCommonPrefix(lines: std.ArrayList([]const u8)) usize {
    var m: usize = std.math.maxInt(usize);
    for (lines.items) |line| {
        var n: usize = std.math.maxInt(usize);
        for (line, 0..) |c, i| {
            if (c != ' ') {
                n = i;
                break;
            }
        }
        m = @min(m, n);
    }
    return m;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    const alloc = arena.allocator();

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len != 2) {
        std.debug.print("invalid number of arguments provided!", .{});
        std.process.exit(1);
    }

    const path = args[1];

    var output = try std.fs.cwd().createFile(path, .{});
    defer output.close();

    try searchConfigAst(alloc, output);
    try searchActionsAst(alloc, output);
}
