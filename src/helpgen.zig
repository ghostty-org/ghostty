//! This program is used to generate the help strings from the configuration
//! file and CLI actions for Ghostty. These can then be used to generate
//! help, docs, website, etc.

const std = @import("std");
const Config = @import("config/Config.zig");
const Action = @import("cli.zig").ghostty.Action;
const KeybindAction = @import("input/Binding.zig").Action;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const alloc = gpa.allocator();

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\// THIS FILE IS AUTO GENERATED
        \\
        \\
    );

    try genConfig(alloc, stdout);
    try genActions(alloc, stdout);
    try genKeybindActions(alloc, stdout);
}

fn genConfig(alloc: std.mem.Allocator, writer: anytype) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("config/Config.zig"), .zig);
    defer ast.deinit(alloc);

    try writer.writeAll(
        \\/// Configuration help
        \\pub const Config = struct {
        \\
        \\
    );

    inline for (@typeInfo(Config).@"struct".fields) |field| {
        if (field.name[0] == '_') continue;
        try genConfigField(alloc, writer, ast, field.name);
    }

    try writer.writeAll("};\n");
}

fn genConfigField(
    alloc: std.mem.Allocator,
    writer: anytype,
    ast: std.zig.Ast,
    comptime field: []const u8,
) !void {
    const tokens = ast.tokens.items(.tag);
    for (tokens, 0..) |token, i| {
        // We only care about identifiers that are preceded by doc comments.
        if (token != .identifier) continue;
        if (tokens[i - 1] != .doc_comment) continue;

        // Identifier may have @"" so we strip that.
        const name = ast.tokenSlice(@intCast(i));
        const key = if (name[0] == '@') name[2 .. name.len - 1] else name;
        if (!std.mem.eql(u8, key, field)) continue;

        const comment = try extractDocComments(alloc, ast, @intCast(i - 1), tokens);
        try writer.writeAll("pub const ");
        try writer.writeAll(name);
        try writer.writeAll(": [:0]const u8 = \n");
        try writer.writeAll(comment);
        try writer.writeAll("\n");
        break;
    }
}

fn genActions(alloc: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll(
        \\
        \\/// Actions help
        \\pub const Action = struct {
        \\
        \\
    );

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        const action_file = comptime action_file: {
            const action = @field(Action, field.name);
            break :action_file action.file();
        };

        var ast = try std.zig.Ast.parse(alloc, @embedFile(action_file), .zig);
        defer ast.deinit(alloc);
        const tokens: []std.zig.Token.Tag = ast.tokens.items(.tag);

        for (tokens, 0..) |token, i| {
            // We're looking for a function named "run".
            if (token != .keyword_fn) continue;
            if (!std.mem.eql(u8, ast.tokenSlice(@intCast(i + 1)), "run")) continue;

            // The function must be preceded by a doc comment.
            if (tokens[i - 2] != .doc_comment) {
                std.debug.print(
                    "doc comment must be present on run function of the {s} action!",
                    .{field.name},
                );
                std.process.exit(1);
            }

            const comment = try extractDocComments(alloc, ast, @intCast(i - 2), tokens);
            try writer.writeAll("pub const @\"");
            try writer.writeAll(field.name);
            try writer.writeAll("\" = \n");
            try writer.writeAll(comment);
            try writer.writeAll("\n\n");
            break;
        }
    }

    try writer.writeAll("};\n");
}

fn genKeybindActions(alloc: std.mem.Allocator, writer: anytype) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("input/Binding.zig"), .zig);
    defer ast.deinit(alloc);

    try writer.writeAll(
        \\/// keybind actions help
        \\pub const KeybindAction = struct {
        \\
        \\
    );

    inline for (@typeInfo(KeybindAction).@"union".fields) |field| {
        if (field.name[0] == '_') continue;
        try genConfigField(alloc, writer, ast, field.name);
    }

    try writer.writeAll("};\n");
}

fn extractDocComments(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    index: std.zig.Ast.TokenIndex,
    tokens: []std.zig.Token.Tag,
) ![]const u8 {
    // Find the first index of the doc comments. The doc comments are
    // always stacked on top of each other so we can just go backwards.
    const start_idx: usize = start_idx: for (0..index) |i| {
        const reverse_i = index - i - 1;
        const token = tokens[reverse_i];
        if (token != .doc_comment) break :start_idx reverse_i + 1;
    } else unreachable;

    // Go through and build up the lines.
    var lines = std.ArrayList([]const u8).init(alloc);
    defer lines.deinit();
    for (start_idx..index + 1) |i| {
        const token = tokens[i];
        if (token != .doc_comment) break;
        try lines.append(ast.tokenSlice(@intCast(i))[3..]);
    }

    // Convert the lines to a multiline string.
    var buffer = std.ArrayList(u8).init(alloc);
    const writer = buffer.writer();
    const prefix = findCommonPrefix(lines);
    for (lines.items) |line| {
        try writer.writeAll("    \\\\");
        try writer.writeAll(line[@min(prefix, line.len)..]);
        try writer.writeAll("\n");
    }
    try writer.writeAll(";\n");

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
