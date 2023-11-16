const std = @import("std");
const ziglyph = @import("ziglyph");
const Generated = @import("generate");
const Action = @import("../cli/action.zig").Action;
const Ast = std.zig.Ast;
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;
const Config = @import("../config/Config.zig");
const Token = std.zig.Token;

pub fn run(alloc: Allocator) !u8 {
    var generated: Generated = .{};

    const stdout = std.io.getStdOut().writer();
    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);

    if (args.len == 2) try stdout.print(
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

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help")) continue;
        const key = parseArgKey(arg);

        if (key.len == 0) continue;

        inline for (@typeInfo(@TypeOf(generated)).Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, key)) {
                try stdout.print(" {s}:\n", .{try ziglyph.toUpperStr(alloc, field.name)});
                try stdout.print("{s}\n\n", .{@field(&generated, field.name)});
            }
        }
    }

    return 0;
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
