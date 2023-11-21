const std = @import("std");
const ziglyph = @import("ziglyph");
const Action = @import("../cli.zig").Action;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Ast = std.zig.Ast;
const Config = @import("config/Config.zig");

const Generator = struct {
    alloc: Allocator,

    config: Config,

    ast: Ast,

    pub fn init(allocator: Allocator) !Generator {
        var parsed = try Ast.parse(allocator, @embedFile("config/Config.zig"), .zig);
        errdefer parsed.deinit(allocator);

        return .{
            .alloc = allocator,
            .ast = parsed,
            .config = .{},
        };
    }

    pub fn deinit(self: *Generator) void {
        self.ast.deinit(self.alloc);

        self.* = undefined;
    }

    pub fn searchConfigAst(self: *Generator, path: [:0]const u8) !void {
        var output = try std.fs.cwd().createFile(path, .{});
        defer output.close();

        const tokens = self.ast.tokens.items(.tag);

        var set = std.StringHashMap(bool).init(self.alloc);
        defer set.deinit();

        _ = try output.write(
            \\//THIS FILE IS AUTO GENERATED
            \\//DO NOT MAKE ANY CHANGES TO THIS FILE!
            \\
            \\const Generated = @This();
            \\
        );

        inline for (@typeInfo(@TypeOf(self.config)).Struct.fields) |field| {
            try set.put(field.name, false);
        }

        var index: u32 = 0;
        while (true) : (index += 1) {
            if (index >= tokens.len) break;
            const token = tokens[index];

            if (token == .identifier) {
                const slice = self.ast.tokenSlice(index);
                // We need this check because the ast grabs the identifier with @"" in case it's used.
                const key = if (slice[0] == '@') slice[2 .. slice.len - 1] else slice;

                if (set.get(key)) |value| {
                    if (value) continue;
                    const comment = try self.consumeDocComments(findFirstDocComment(index, &tokens), &tokens);
                    const prop_type = ": " ++ "[:0]const u8 " ++ "= " ++ "\n";

                    const concat = try std.mem.concat(self.alloc, u8, &.{ slice, prop_type });
                    _ = try output.write(concat);
                    _ = try output.write(comment);
                    _ = try output.write("\n\n");

                    try set.put(key, true);
                }
            }
            if (token == .eof) break;
        }
    }

    const ActionPath = struct { version: []const u8, @"list-keybinds": []const u8, @"list-fonts": []const u8 };

    pub fn searchActionsAst(self: *Generator, path: [:0]const u8) !void {
        const paths = ActionPath{ .version = "cli/version.zig", .@"list-fonts" = "cli/list_fonts.zig", .@"list-keybinds" = "cli/list_keybinds.zig" };

        var output = try std.fs.cwd().openFile(path, .{ .mode = .read_write });
        try output.seekFromEnd(0);
        defer output.close();

        inline for (@typeInfo(@TypeOf(paths)).Struct.fields) |field| {
            self.ast = try Ast.parse(self.alloc, @embedFile(@field(paths, field.name)), .zig);
            const tokens = self.ast.tokens.items(.tag);

            var index: u32 = 0;
            while (true) : (index += 1) {
                if (tokens[index] == .keyword_fn) {
                    if (std.mem.eql(u8, self.ast.tokenSlice(index + 1), "run")) {
                        if (tokens[index - 2] != .doc_comment) {
                            std.debug.print("doc comment must be present on run function of the {s} action!", .{field.name});
                            std.process.exit(1);
                        }
                        const comment = try self.consumeDocComments(findFirstDocComment(index, &tokens), &tokens);
                        const prop_type = "@\"" ++ field.name ++ "\"" ++ ": " ++ "[:0]const u8 " ++ "= " ++ "\n";

                        _ = try output.write(prop_type);
                        _ = try output.write(comment);
                        _ = try output.write("\n\n");
                        break;
                    }
                }
            }
        }
    }

    fn consumeDocComments(self: *Generator, index: Ast.TokenIndex, toks: anytype) ![]const u8 {
        var lines = std.ArrayList([]const u8).init(self.alloc);
        defer lines.deinit();

        const tokens = toks.*;
        var current_idx = index;

        // We iterate backwards because the doc_comment tokens should be on top of each other in case there are any.
        while (true) : (current_idx -= 1) {
            const doc_comment = tokens[current_idx];

            if (doc_comment == .doc_comment) {
                // Insert at 0 so that we don't have the text in reverse.
                try lines.insert(0, try std.mem.concat(self.alloc, u8, &.{ "    \\\\", self.ast.tokenSlice(current_idx)[3..] }));
            } else break;
        }

        try lines.append(",");

        return try std.mem.join(self.alloc, "\n", lines.items);
    }

    fn findFirstDocComment(index: Ast.TokenIndex, toks: anytype) Ast.TokenIndex {
        var current_idx = index;
        const tokens = toks.*;

        // We iterate backwards because the doc_comment token should be on top of the identifier token.
        while (true) : (current_idx -= 1) {
            if (tokens[current_idx] == .doc_comment) return current_idx;
        }
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var arena_alloc = ArenaAllocator.init(gpa.allocator());
    const alloc = arena_alloc.allocator();

    var generated = try Generator.init(alloc);
    const args = try std.process.argsAlloc(alloc);
    defer {
        generated.deinit();
        std.process.argsFree(alloc, args);
    }

    if (args.len != 2) {
        std.debug.print("invalid number of arguments provided!", .{});
        std.process.exit(1);
    }

    const path = args[1];

    try generated.searchConfigAst(path);
    try generated.searchActionsAst(path);
}
