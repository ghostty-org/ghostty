const std = @import("std");
const Allocator = std.mem.Allocator;

const list_fonts = @import("list_fonts.zig");
const version = @import("version.zig");
const list_keybinds = @import("list_keybinds.zig");
const help = @import("help.zig");

/// Special commands that can be invoked via CLI flags. These are all
/// invoked by using `+<action>` as a CLI flag. The only exception is
/// "version" which can be invoked additionally with `--version`.
pub const Action = enum {
    /// Output the version and exit
    version,

    /// List available fonts
    @"list-fonts",

    /// List available keybinds
    @"list-keybinds",

    /// List general or config/actions help information
    help,

    pub const Error = error{
        /// Multiple actions were detected. You can specify at most one
        /// action on the CLI otherwise the behavior desired is ambiguous.
        MultipleActions,

        /// An unknown action was specified.
        InvalidAction,
    };

    /// Detect the action from CLI args.
    pub fn detectCLI(alloc: Allocator) !?Action {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        return try detectIter(&iter);
    }

    /// Detect the action from any iterator, used primarily for tests.
    pub fn detectIter(iter: anytype) Error!?Action {
        var pending: ?Action = null;
        while (iter.next()) |arg| {
            // Special case, --version always outputs the version no
            // matter what, no matter what other args exist.
            if (std.mem.eql(u8, arg, "--version")) return .version;
            if (std.mem.eql(u8, arg, "--help")) return .help;

            // Commands must start with "+"
            if (arg.len == 0 or arg[0] != '+') continue;
            if (pending != null) return Error.MultipleActions;
            pending = std.meta.stringToEnum(Action, arg[1..]) orelse return Error.InvalidAction;
        }

        return pending;
    }

    /// Run the action. This returns the exit code to exit with.
    pub fn run(self: Action, alloc: Allocator) !u8 {
        return switch (self) {
            .version => try version.run(alloc),
            .help => try help.run(alloc),
            .@"list-fonts" => try list_fonts.run(alloc),
            .@"list-keybinds" => try list_keybinds.run(alloc),
        };
    }
};

test "parse action none" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var iter = try std.process.ArgIteratorGeneral(.{}).init(
        alloc,
        "--a=42 --b --b-f=false",
    );
    defer iter.deinit();
    const action = try Action.detectIter(&iter);
    try testing.expect(action == null);
}

test "parse action version" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --version",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d --version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }
}

test "parse action plus" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +version",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "+version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d +version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.? == .version);
    }
}
