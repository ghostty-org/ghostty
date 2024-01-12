const std = @import("std");
const help_strings = @import("help_strings"){};
const Action = @import("../cli/action.zig").Action;
const Config = @import("../config/Config.zig");

/// Print help text about the options or actions specified on the command line.
pub fn run(alloc: std.mem.Allocator) !u8 {
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

        var found = false;

        inline for (@typeInfo(@TypeOf(help_strings)).Struct.fields) |field| {
            if (std.mem.eql(u8, field.name, key)) {
                found = true;
                try stdout.print("{s}:\n", .{arg});
                var iter = std.mem.splitScalar(u8, @field(help_strings, field.name), '\n');
                while (iter.next()) |line| {
                    try stdout.print("  {s}\n", .{line});
                }
            }
        }

        if (!found) {
            try stdout.print("{s}: no help found!\n", .{arg});
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
        return arg;
    }

    if (std.mem.eql(u8, arg, "-e")) {
        return "command";
    }

    return "";
}
