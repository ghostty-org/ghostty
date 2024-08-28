//! This program is used to generate JSON data from the configuration file
//! and CLI actions for Ghostty. This can then be used to generate help, docs,
//! website, etc.

const std = @import("std");
const formatter = @import("config/formatter.zig");
const Config = @import("config/Config.zig");
const Action = @import("cli/action.zig").Action;
const KeybindAction = @import("input/Binding.zig").Action;

pub const Help = struct {
    config: []ConfigInfo,
    actions: []ActionInfo,
    keybind_actions: []KeybindActionInfo,
    enums: []EnumInfo,
};

pub const ConfigInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    type: []const u8,
    default: ?[]const u8 = null,
};

pub const ActionInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
};

pub const KeybindActionInfo = struct {
    name: []const u8,
    help: ?[]const u8 = null,
    type: []const u8,
    default: ?[]const u8 = null,
};

pub const EnumInfo = struct {
    name: []const u8,
    help: ?[]const u8,
    values: []EnumValue,
};

pub const EnumValue = struct {
    value: []const u8,
    help: ?[]const u8,
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    const alloc = arena.allocator();
    defer arena.deinit();

    const stdout = std.io.getStdOut().writer();

    var config_list = std.ArrayList(ConfigInfo).init(alloc);
    errdefer config_list.deinit();

    var enum_hash = std.StringArrayHashMap(EnumInfo).init(alloc);

    try genConfig(alloc, &config_list, &enum_hash);

    var actions_list = std.ArrayList(ActionInfo).init(alloc);
    errdefer config_list.deinit();

    try genActions(alloc, &actions_list);

    var keybind_actions_list = std.ArrayList(KeybindActionInfo).init(alloc);
    errdefer config_list.deinit();

    try genKeybindActions(alloc, &keybind_actions_list, &enum_hash);

    const j = Help{
        .config = try config_list.toOwnedSlice(),
        .actions = try actions_list.toOwnedSlice(),
        .keybind_actions = try keybind_actions_list.toOwnedSlice(),
        .enums = enum_hash.values(),
    };

    try std.json.stringify(j, .{ .whitespace = .indent_2 }, stdout);
}

fn genConfig(
    alloc: std.mem.Allocator,
    config_list: *std.ArrayList(ConfigInfo),
    enum_hash: *std.StringArrayHashMap(EnumInfo),
) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("config/Config.zig"), .zig);
    defer ast.deinit(alloc);

    inline for (@typeInfo(Config).Struct.fields) |field| {
        if (field.name[0] == '_') continue;
        const default_value = d: {
            if (field.default_value) |dv| {
                const v: *const field.type = @ptrCast(@alignCast(dv));
                var l = std.ArrayList(u8).init(alloc);
                errdefer l.deinit();
                try formatter.formatEntry(
                    field.type,
                    field.name,
                    v.*,
                    l.writer(),
                );
                break :d try l.toOwnedSlice();
            }
            break :d "(none)";
        };
        if (@typeInfo(field.type) == .Enum) try genEnum(
            field.type,
            alloc,
            enum_hash,
        );
        try genConfigField(
            alloc,
            ConfigInfo,
            config_list,
            ast,
            field.name,
            @typeName(field.type),
            default_value,
        );
    }
}

fn genActions(alloc: std.mem.Allocator, actions_list: *std.ArrayList(ActionInfo)) !void {
    inline for (@typeInfo(Action).Enum.fields) |field| {
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

            try actions_list.append(
                .{
                    .name = field.name,
                    .help = comment,
                },
            );

            break;
        }
    }
}

fn genKeybindActions(
    alloc: std.mem.Allocator,
    keybind_actions_list: *std.ArrayList(KeybindActionInfo),
    enum_hash: *std.StringArrayHashMap(EnumInfo),
) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("input/Binding.zig"), .zig);
    defer ast.deinit(alloc);

    inline for (@typeInfo(KeybindAction).Union.fields) |field| {
        if (field.name[0] == '_') continue;
        if (@typeInfo(field.type) == .Enum) try genEnum(
            field.type,
            alloc,
            enum_hash,
        );
        try genConfigField(
            alloc,
            KeybindActionInfo,
            keybind_actions_list,
            ast,
            field.name,
            @typeName(field.type),
            null,
        );
    }
}

fn genConfigField(
    alloc: std.mem.Allocator,
    comptime T: type,
    list: *std.ArrayList(T),
    ast: std.zig.Ast,
    comptime field: []const u8,
    comptime type_name: []const u8,
    default_value: ?[]const u8,
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
        try list.append(.{ .name = field, .help = comment, .type = type_name, .default = default_value });
        break;
    }
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

    var buffer = std.ArrayList(u8).init(alloc);
    const writer = buffer.writer();
    const prefix = findCommonPrefix(lines);
    for (lines.items) |line| {
        try writer.writeAll(line[@min(prefix, line.len)..]);
        try writer.writeAll("\n");
    }

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

fn genEnum(comptime T: type, alloc: std.mem.Allocator, enum_map: *std.StringArrayHashMap(EnumInfo)) !void {
    const long_name = @typeName(T);

    if (enum_map.contains(long_name)) return;

    const source = s: {
        if (std.mem.startsWith(u8, long_name, "config.Config.")) break :s @embedFile("config/Config.zig");
        if (std.mem.startsWith(u8, long_name, "input.Binding.")) break :s @embedFile("input/Binding.zig");
        if (std.mem.startsWith(u8, long_name, "terminal.Screen.")) break :s @embedFile("terminal/Screen.zig");
        std.log.warn("unsupported enum {s}", .{long_name});
        return;
    };

    var it = std.mem.splitScalar(u8, long_name, '.');
    _ = it.next();
    _ = it.next();

    var ast = try std.zig.Ast.parse(alloc, source, .zig);
    defer ast.deinit(alloc);

    const tokens = ast.tokens.items(.tag);

    var short_name: []const u8 = "";
    var start: std.zig.Ast.TokenIndex = 0;
    var end: std.zig.Ast.TokenIndex = @intCast(tokens.len);

    while (it.next()) |s| {
        const e = findDefinition(ast, tokens, s, start, end) orelse {
            @panic("can't find " ++ long_name);
        };
        short_name = s;
        start = e.start;
        end = e.end;
    }

    const comment = if (start >= 2) try extractDocComments(alloc, ast, @intCast(start - 2), tokens) else null;

    var values = std.ArrayList(EnumValue).init(alloc);
    errdefer values.deinit();

    for (tokens[start..end], start..) |token, j| {
        if (token != .identifier) continue;
        switch (tokens[j + 1]) {
            .equal => {
                if (tokens[j + 2] != .number_literal) continue;
                if (tokens[j + 3] != .comma) continue;
            },
            .comma => {},
            else => continue,
        }

        const value_name = ast.tokenSlice(@intCast(j));
        const value_key = if (value_name[0] == '@') value_name[2 .. value_name.len - 1] else value_name;
        const value_comment = try extractDocComments(alloc, ast, @intCast(j - 1), tokens);
        try values.append(
            .{
                .value = value_key,
                .help = value_comment,
            },
        );
    }

    try enum_map.put(
        long_name,
        .{
            .name = long_name,
            .help = comment,
            .values = try values.toOwnedSlice(),
        },
    );
}

fn findDefinition(
    ast: std.zig.Ast,
    tokens: []std.zig.Token.Tag,
    name: []const u8,
    start: std.zig.Ast.TokenIndex,
    end: std.zig.Ast.TokenIndex,
) ?struct {
    identifier: std.zig.Ast.TokenIndex,
    start: std.zig.Ast.TokenIndex,
    end: std.zig.Ast.TokenIndex,
} {
    for (tokens[start..end], start..) |token, i| {
        if (token != .identifier) continue;

        if (i < 2) continue;

        const identifier: std.zig.Ast.TokenIndex = @intCast(i);

        if (tokens[i - 2] != .keyword_pub) continue;
        if (tokens[i - 1] != .keyword_const) continue;
        if (tokens[i + 1] != .equal) continue;

        if (!std.mem.eql(u8, name, ast.tokenSlice(identifier))) continue;

        const start_brace: std.zig.Ast.TokenIndex = s: {
            for (tokens[i..end], i..) |t, j| {
                if (t == .l_brace) break :s @intCast(j);
            }
            return null;
        };

        var depth: usize = 0;

        for (tokens[start_brace..], start_brace..) |tok, j| {
            if (tok == .l_brace) depth += 1;
            if (tok == .r_brace) depth -= 1;
            if (depth == 0) {
                return .{
                    .identifier = identifier,
                    .start = start_brace + 1,
                    .end = @intCast(j - 1),
                };
            }
        }
    }
    return null;
}
