const std = @import("std");
const args = @import("../cli/args.zig");
const ziglyph = @import("ziglyph");
const Action = @import("../cli/action.zig").Action;
const Ast = std.zig.Ast;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");

const ArgumentType = enum {
    config_type,
    action_type,
    none,
};

pub fn run(alloc: Allocator) !u8 {
    const stdout = std.io.getStdOut().writer();
    var iter = try std.process.argsWithAllocator(alloc);
    defer iter.deinit();

    var count: u8 = 0;
    while (iter.next()) |arg| {
        count += 1;
        if (std.mem.eql(u8, arg, "--help")) continue;
        const key = parseArgKey(arg);

        if (key.len == 0) continue;

        const arg_type = findArgumentType(key);
        switch (arg_type) {
            .config_type => try searchConfigAst(key, alloc, &stdout),
            .action_type => try searchActionsAst(key, alloc, &stdout),
            inline else => try stdout.print("Invalid argument provided: {s}\n", .{key}),
        }
    }

    if (count == 2) try stdout.print(
        \\To list help for config options use:
        \\ghostty [--config_options] --help
        \\ghostty --help [--config_options]
        \\
        \\To list help for actions use:
        \\ghostty [+action] --help (This will only print the help for the specific action)
        \\ghostty --help [+action] (With this you can use it for multiple actions)
        \\
        \\You can also list help for both options and actions by using one of following
        \\ghostty --help [--config_options] [+action]
        \\ghostty --help [+action] [--config_options]
    , .{});

    return 0;
}

pub fn searchActionsAst(key: []const u8, alloc: Allocator, stdout: anytype) !void {
    // This is safe to do since this will only be called with a valid action
    const source = switch (std.meta.stringToEnum(Action, key).?) {
        .@"list-keybinds" => @embedFile("list_keybinds.zig"),
        .@"list-fonts" => @embedFile("list_fonts.zig"),
        .version => @embedFile("version.zig"),
        else => return error.UnsupportedHelpAction,
    };

    var new_ast = try Ast.parse(alloc, source, .zig);
    defer new_ast.deinit(alloc);

    const tokens = new_ast.tokens.items(.tag);
    var index: u32 = 0;

    while (true) : (index += 1) {
        if (tokens[index] == .keyword_fn) {
            if (std.mem.eql(u8, new_ast.tokenSlice(index + 1), "run")) {
                const comment = try consumeDocComments(alloc, new_ast, findFirstDocComment(index, tokens), tokens);

                try stdout.print(" {s}:\n", .{try ziglyph.toUpperStr(alloc, key)});
                try stdout.print("{s}", .{comment});
                try stdout.print("\n\n", .{});
                break;
            }
        }
    }
}

fn searchConfigAst(key: []const u8, alloc: Allocator, stdout: anytype) !void {
    const config_source = @embedFile("../config/Config.zig");
    var ast = try std.zig.Ast.parse(alloc, config_source, .zig);
    defer ast.deinit(alloc);

    const tokens = ast.tokens.items(.tag);
    var index: u32 = 0;

    while (true) : (index += 1) {
        const token = tokens[index];

        if (token == .identifier) {
            const slice = ast.tokenSlice(index);
            // We need this check because the ast grabs the identifier with @"" in case it's used.
            if (slice[0] == '@') {
                if (std.mem.eql(u8, slice[2 .. slice.len - 1], key)) {
                    const comment = try consumeDocComments(alloc, ast, findFirstDocComment(index, tokens), tokens);

                    try stdout.print(" {s}:\n", .{try ziglyph.toUpperStr(alloc, key)});
                    try stdout.print("{s}", .{comment});
                    try stdout.print("\n\n", .{});
                    break;
                }
            }
            if (std.mem.eql(u8, slice, key)) {
                const comment = try consumeDocComments(alloc, ast, findFirstDocComment(index, tokens), tokens);

                try stdout.print(" {s}:\n", .{try ziglyph.toUpperStr(alloc, key)});
                try stdout.print("{s}", .{comment});
                try stdout.print("\n\n", .{});
                break;
            }
        }
    }
}

fn findFirstDocComment(index: u32, tokens: anytype) u32 {
    var current_idx = index;

    // We iterate backwards because the doc_comment token should be on top of the identifier token.
    while (true) : (current_idx -= 1) {
        if (tokens[current_idx] == .doc_comment) return current_idx;
    }
}

fn consumeDocComments(alloc: Allocator, ast: Ast, index: Ast.TokenIndex, tokens: anytype) ![]const u8 {
    var lines = std.ArrayList([]const u8).init(alloc);
    defer lines.deinit();

    var current_idx = index;

    // We iterate backwards because the doc_comment tokens should be on top of each other in case there are any.
    while (true) : (current_idx -= 1) {
        const doc_comment = tokens[current_idx];

        if (doc_comment == .doc_comment) {
            // Insert at 0 so that we don't have the text in reverse.
            try lines.insert(0, ast.tokenSlice(current_idx)[3..]);
        } else break;
    }

    return try std.mem.join(alloc, "\n", lines.items);
}

fn parseArgKey(arg: []const u8) []const u8 {
    if (std.mem.startsWith(u8, arg, "--")) {
        var key = arg[2..];
        if (std.mem.indexOf(u8, key, "=")) |idx| {
            key = key[0..idx];
        }

        return key;
    }

    if (std.mem.startsWith(u8, arg, "+")) {
        var key = arg[1..];

        return key;
    }

    if (std.mem.eql(u8, arg, "-e")) {
        return "command-arg";
    }

    return "";
}

fn isConfigStructMember(field_name: []const u8) bool {
    var config: Config = .{};
    inline for (@typeInfo(@TypeOf(config)).Struct.fields) |field| {
        if (std.mem.eql(u8, field_name, field.name)) return true;
    }

    return false;
}

fn isActionMember(key: []const u8) bool {
    return std.meta.stringToEnum(Action, key) != null;
}

fn findArgumentType(key: []const u8) ArgumentType {
    if (isConfigStructMember(key)) return .config_type;
    if (isActionMember(key)) return .action_type;

    return .none;
}
