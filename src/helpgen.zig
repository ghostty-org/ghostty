//! This program is used to generate the help strings from the configuration
//! file and CLI actions for Ghostty. These can then be used to generate
//! help, docs, website, etc.

const std = @import("std");
const Config = @import("config/Config.zig");
const Action = @import("cli/action.zig").Action;
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

    try genStringsStruct(
        alloc,
        writer,
        ast,
        "Config",
        0,
        ast.rootDecls(),
        0,
    );
}

fn genActions(alloc: std.mem.Allocator, writer: anytype) !void {
    try writer.writeAll(
        \\
        \\/// Actions help
        \\pub const Action = struct {
        \\
        \\
    );

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

            const comment = try extractDocComments(
                alloc,
                ast,
                @intCast(i - 2),
                0,
            ) orelse continue;

            try writer.writeAll("pub const @\"");
            try writer.writeAll(field.name);
            try writer.writeAll("\" = \n");
            try writer.writeAll(comment);
            try writer.writeAll(";\n\n");
            break;
        }
    }

    try writer.writeAll("};\n");
}

fn genKeybindActions(alloc: std.mem.Allocator, writer: anytype) !void {
    var ast = try std.zig.Ast.parse(alloc, @embedFile("input/Binding.zig"), .zig);
    defer ast.deinit(alloc);

    try writer.writeAll(
        \\pub const KeybindAction = struct {
        \\
        \\};
    );

    // for (ast.rootDecls()) |decl| {
    //     if (ast.fullVarDecl(decl)) |var_decl| {
    //         var buf: [2]std.zig.Ast.TokenIndex = undefined;
    //         const decl_container = ast.fullContainerDecl(&buf, var_decl.ast.init_node) orelse continue;
    //         const name = ast.tokenSlice(var_decl.ast.mut_token + 1);

    //         if (!std.mem.eql(u8, name, "Action")) continue;

    //         _ = decl_container;
    //         _ = writer;

    // try genStringsStruct(
    //     alloc,
    //     writer,
    //     ast,
    //     "KeybindAction",
    //     decl_container.ast.members,
    //     var_decl.firstToken() - 1,
    // );

    //         return;
    //     }
    // }
}

fn genStringsStruct(
    alloc: std.mem.Allocator,
    writer: anytype,
    ast: std.zig.Ast,
    name: []const u8,
    main_token: std.zig.Ast.TokenIndex,
    members: []const std.zig.Ast.Node.Index,
    doc_comment_token: ?std.zig.Ast.TokenIndex,
) !void {
    var fields: std.ArrayListUnmanaged(std.zig.Ast.full.ContainerField) = .{};
    defer fields.deinit(alloc);

    var decls: std.ArrayListUnmanaged(std.zig.Ast.full.VarDecl) = .{};
    defer decls.deinit(alloc);

    try writer.print("pub const {s} = struct {{\n", .{name});

    for (members) |member| {
        if (ast.fullContainerField(member)) |field| {
            try fields.append(alloc, field);
        } else if (ast.fullVarDecl(member)) |var_decl| {
            // Is it defining a subtype?
            try decls.append(alloc, var_decl);
        }
    }

    for (fields.items) |field| {
        try genConfigField(alloc, writer, ast, field, decls.items);
    }

    for (decls.items) |var_decl| {
        var buf: [2]std.zig.Ast.TokenIndex = undefined;
        const decl_container = ast.fullContainerDecl(&buf, var_decl.ast.init_node) orelse continue;

        try genStringsStruct(
            alloc,
            writer,
            ast,
            ast.tokenSlice(var_decl.ast.mut_token + 1),
            decl_container.ast.main_token,
            decl_container.ast.members,
            var_decl.firstToken() - 1,
        );
    }

    try writer.writeAll(
        \\pub const @"DOC-COMMENT": []const u8 =
        \\
    );

    if (doc_comment_token) |token| {
        if (try extractDocComments(
            alloc,
            ast,
            @intCast(token),
            0,
        )) |comment| {
            try writer.writeAll(comment);
        }
    }

    try genValidValues(
        alloc,
        writer,
        ast,
        main_token,
        members,
    );

    try writer.writeAll(
        \\    \\
        \\;
        \\};
    );
}

fn genValidValues(
    alloc: std.mem.Allocator,
    writer: anytype,
    ast: std.zig.Ast,
    main_token: std.zig.Ast.TokenIndex,
    members: []const std.zig.Ast.Node.Index,
) !void {
    const token_tags = ast.tokens.items(.tag);

    const ContainerType = enum {
        @"enum",
        @"union",
        bitfield,
    };

    const container_type: ContainerType = switch (token_tags[main_token]) {
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_struct => switch (token_tags[main_token - 1]) {
            .keyword_packed => .bitfield,
            else => return,
        },
        else => return,
    };

    try writer.writeAll(
        \\\\
        \\\\Valid values:
        \\\\
        \\
    );

    for (members) |member| {
        const field = ast.fullContainerField(member) orelse continue;
        var field_name = ast.tokenSlice(field.ast.main_token);

        if (std.mem.startsWith(u8, field_name, "@\"")) {
            field_name = field_name[2..][0 .. field_name.len - 3];
        }

        try writer.writeAll(
            \\\\ -
        );

        switch (container_type) {
            .@"enum" => try writer.print(" `{s}`\n", .{field_name}),
            .@"union" => {
                const field_type = ast.getNodeSource(field.ast.type_expr);

                // Only generate the field name if the field is "enum-variant-like":
                // type is void or nonexistent.
                if (field.ast.main_token == ast.firstToken(field.ast.type_expr) or
                    std.mem.eql(u8, field_type, "void"))
                {
                    try writer.print(" `{s}`\n", .{field_name});
                }
            },
            .bitfield => {
                const default_value = ast.tokenSlice(ast.firstToken(field.ast.value_expr));
                const is_default = std.mem.eql(u8, default_value, "true");

                if (is_default) {
                    try writer.print(" [x] `{s}` (Enabled by default)\n", .{field_name});
                } else {
                    try writer.print(" [ ] `{s}`\n", .{field_name});
                }
            },
        }

        try writer.writeAll(
            \\\\
            \\
        );

        if (try extractDocComments(
            alloc,
            ast,
            field.firstToken() - 1,
            3, // 4 indents would be an indented code block
        )) |comment| {
            try writer.writeAll(comment);
            try writer.writeAll(
                \\\\
                \\
            );
        }
    }
}

fn genConfigField(
    alloc: std.mem.Allocator,
    writer: anytype,
    ast: std.zig.Ast,
    field: std.zig.Ast.full.ContainerField,
    decls: []std.zig.Ast.full.VarDecl,
) !void {
    const name = ast.tokenSlice(field.ast.main_token);
    if (name[0] == '_') return;

    // Escape special identifiers that are valid as enum variants but not as field names
    const special_identifiers = &[_][]const u8{ "true", "false", "null" };

    const is_special = for (special_identifiers) |special| {
        if (std.mem.eql(u8, name, special)) break true;
    } else false;

    const comment = try extractDocComments(
        alloc,
        ast,
        field.firstToken() - 1,
        0,
    ) orelse return;

    try writer.writeAll("pub const ");
    if (is_special) try writer.writeAll("@\"");
    try writer.writeAll(name);
    if (is_special) try writer.writeAll("\"");
    try writer.writeAll(": [:0]const u8 = \n");
    try writer.writeAll(comment);

    const type_name = ast.tokenSlice(ast.lastToken(field.ast.type_expr));

    for (decls) |decl| {
        if (std.mem.eql(u8, type_name, ast.tokenSlice(decl.ast.mut_token + 1))) {
            try writer.writeAll(
                \\\\
                \\\\
                \\++
                \\
            );
            try writer.writeAll(type_name);
            try writer.writeAll(
                \\.@"DOC-COMMENT"
                \\
            );
        }
    }

    try genDefaultValue(writer, ast, field);

    try writer.writeAll(";\n");
}

fn genDefaultValue(
    writer: anytype,
    ast: std.zig.Ast,
    field: std.zig.Ast.full.ContainerField,
) !void {
    const value = ast.nodes.get(field.ast.value_expr);

    switch (value.tag) {
        .number_literal, .string_literal => {
            try writer.writeAll(
                \\++
                \\\\
                \\\\Defaults to `{s}`.
            , ast.getNodeSource(field.ast.value_expr));
        },
        .identifier, .number_literal, .string_literal, .enum_literal => {
            try writer.writeAll(
                \\++
                \\\\
                \\\\
                \\\\
            );

            const default = switch (value.tag) {
                .enum_literal, .identifier => id: {
                    // Escape @"blah"
                    const slice = ast.tokenSlice(value.main_token);
                    break :id if (std.mem.startsWith(u8, slice, "@\""))
                        slice[2..][0 .. slice.len - 3]
                    else
                        slice;
                },
                .number_literal => ast.tokenSlice(value.main_token),
                // We really don't know. Guess.
                else => ast.getNodeSource(field.ast.value_expr),
            };

            // var default = ast.getNodeSource(field.ast.value_expr);
            // if (default[0] == '.') {
            //     default = default[1..];
            // }

            if (std.mem.eql(u8, default, "null")) {
                try writer.writeAll("Unset by default.\n");
                return;
            }

            const default_type_node = ast.nodes.get(field.ast.type_expr);
            // ?bool is still semantically boolean
            const default_type = if (default_type_node.tag == .optional_type)
                ast.getNodeSource(default_type_node.data.lhs)
            else
                ast.getNodeSource(field.ast.type_expr);

            // There are some enums/tagged unions with variants called `true`
            // or `false`, and it's not accurate to call them enabled or
            // disabled in some circumstances.
            // Thus we only consider booleans here.
            if (std.mem.eql(u8, default_type, "bool")) {
                if (std.mem.eql(u8, default, "true")) {
                    try writer.writeAll("Enabled by default.\n");
                } else if (std.mem.eql(u8, default, "false")) {
                    try writer.writeAll("Disabled by default.\n");
                }
                return;
            }

            try writer.print("Defaults to `{s}`.\n", .{default});
        },
        else => {},
    }
}

fn extractDocComments(
    alloc: std.mem.Allocator,
    ast: std.zig.Ast,
    index: std.zig.Ast.TokenIndex,
    comptime indent: usize,
) !?[]const u8 {
    if (index == 0) return null;
    const tokens = ast.tokens.items(.tag);

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

    if (lines.items.len == 0) return null;
    for (lines.items) |line| {
        try writer.writeAll("    \\\\" ++ " " ** indent);
        try writer.writeAll(line[@min(prefix, line.len)..]);
        try writer.writeAll("\n");
    }

    return try buffer.toOwnedSlice();
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
