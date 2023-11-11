const std = @import("std");
const Allocator = std.mem.Allocator;

const list_fonts = @import("list_fonts.zig");
const version = @import("version.zig");
const list_keybinds = @import("list_keybinds.zig");

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

    /// help flag. Provides overall help as well as help for specific action.
    /// Can be called as --help or +help
    help,

    /// comptime type dispatch based on Action enum. Use to simplify switch statements.
    pub inline fn ToType(comptime self: Action) type {
        return switch (self) {
            .version            => version,
            .@"list-fonts"      => list_fonts,
            .@"list-keybinds"   => list_keybinds,
            .help               => Help,
        };
    }

    pub const Error = error{
        /// Multiple actions were detected. You can specify at most one
        /// action on the CLI otherwise the behavior desired is ambiguous.
        MultipleActions,

        /// An unknown action was specified.
        InvalidAction,
    };

    /// Detect the action from CLI args.
    pub fn detectCLI(alloc: Allocator) !?ActionXtra {
        var iter = try std.process.argsWithAllocator(alloc);
        defer iter.deinit();
        return try detectIter(&iter);
    }

    /// Detect the action from any iterator, used primarily for tests.
    pub fn detectIter(iter: anytype) Error!?ActionXtra {
        var pending: ?Action = null;
        var oa: ?Action = null;
        var ox: ?Action = null;
        var cnt: i32 = 0;
        while (iter.next()) |arg| {
            // Special case, --version always outputs the version no
            // matter what, no matter what other args exist.
            if (std.mem.eql(u8, arg, "--version")) {
                pending = .version;
            } else if (std.mem.eql(u8, arg, "--help")) {
                pending = .help;
            } else {
                // Commands must start with "+"
                if (arg.len == 0 or arg[0] != '+') continue;
                pending = std.meta.stringToEnum(Action, arg[1..]) orelse return Error.InvalidAction;
            }
            cnt +=1;
            // keeping track
            if ((oa != .help) and (pending == .help)) {
                cnt -= 1;
                ox = oa;
                oa = .help;
            } else if (oa == .help) {
                ox = pending;
            } else {
                oa = pending;
            }
            if (cnt > 1) return Error.MultipleActions;
        }
        return if (oa) |a| .{.action = a, .xtra = ox} else null;
    }

    /// Run the action. This returns the exit code to exit with.
    pub fn run(self: Action, alloc: Allocator) !u8 {
        return switch (self) {
            // .help => |act| act.ToType().help(alloc),
            inline else => |act| try act.ToType().run(alloc),
        };
    }

    pub fn write_help(self: Action, alloc: Allocator, writer: anytype, short: bool) anyerror!u8 {
        return switch (self) {
            inline else => |act| try act.ToType().help(alloc, writer, short),
        };
    }

    /// Run the action. This returns the exit code to exit with.
    pub fn run_DISABLED(self: Action, alloc: Allocator) !u8 {
        return switch (self) {
            .version => try version.run(alloc),
            .@"list-fonts" => try list_fonts.run(alloc),
            .@"list-keybinds" => try list_keybinds.run(alloc),
        };
    }
};

/// ActionXtra supports --help for actions
pub const ActionXtra = struct {
    action: Action,
    xtra: ?Action,
    
    const Self = @This();

    pub fn run(self: Self, alloc: Allocator) !u8 {
        switch (self.action) { 
            inline else => |a| {return try a.ToType().run(alloc);}
        }
    }

    pub fn help(self: Self, alloc: Allocator, writer: anytype) !u8 {
        if (self.action == .help) {
            if (self.xtra) |x| { // long action help
                switch (x) { 
                    inline else => |a| {return try a.ToType().help(alloc, writer, false);}
                }
            } else { // general ghostty help screen
                return try Help.generate_help(alloc, writer, true);
                }
        } else {
            return 127;
        }
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
        const action_xtra = try Action.detectIter(&iter);
        try testing.expect(action_xtra.?.action == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d --version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .version);
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
        try testing.expect(action.?.action == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "+version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--c=84 --d +version --a=42 --b --b-f=false",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .version);
    }
}

test "parse action help" {
    const testing = std.testing;
    const alloc = testing.allocator;

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --help",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .help);
        try testing.expect(action.?.xtra == null);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false --help +version",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .help);
        try testing.expect(action.?.xtra == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +version --help",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .help);
        try testing.expect(action.?.xtra == .version);
    }

    {
        var iter = try std.process.ArgIteratorGeneral(.{}).init(
            alloc,
            "--a=42 --b --b-f=false +help",
        );
        defer iter.deinit();
        const action = try Action.detectIter(&iter);
        try testing.expect(action.?.action == .help);
        try testing.expect(action.?.xtra == null);
    }

}

pub const Help = struct {

    pub fn help(
        alloc: Allocator, // in case of dynamically generated help
        writer: anytype, // duck-typing, print to any writer including ArrayList
        short: bool // short one-line (<68 letters, no NL) or long (unlimited size) help
    ) !u8 {
        _ = alloc;
    if (short) {
        try writer.print("Display help messages.  Use as +help or --help", .{});
    } else {
        try writer.print( "{s}\n", .{cli_welcome_msg});
    }

        return 42;
    }

    pub fn run(_: anytype) !u8 { return 0; }

    fn generate_help(alloc: Allocator, writer: anytype, short:bool) !u8 {
        _ = short;
        var action_max_len: usize = 0;
        const fields = @typeInfo(Action).Enum.fields;
        inline for (fields) |fld| {
            if (fld.name.len > action_max_len) action_max_len = fld.name.len;
        }

        try writer.print(
            \\Ghostty helper CLI
            \\Usage:
            \\  ghostty +some_action [options...] [arguments...]
            \\
            \\where some_action is one of the following:
            \\
        , .{});

        inline for (fields) |fld| {
            const name = fld.name;
            try writer.print("  {[name]s: <[w]} - ", .{.name=name, .w=action_max_len});
            _ = try @field(Action, name).write_help(alloc, writer, true);
            _ = try writer.write("\n");
        }


        try writer.print(
            \\
            \\For help about specific action try "ghostty --help +<action>" or "ghostty +<action> --help"
            \\The +help action can be used in place of the --help option.
            \\
        , .{});

        return 0;
    }

};

pub const cli_welcome_msg = 
    \\Usage: ghostty +<action> [flags]
    \\
    \\This is the Ghostty helper CLI that accompanies the graphical Ghostty app.
    \\To launch the terminal directly, please launch the graphical app
    \\(i.e. Ghostty.app on macOS). This CLI can be used to perform various
    \\actions such as inspecting the version, listing fonts, etc.
    \\
    \\Try "ghostty --help" for help on available CLI actions.
    \\Please refer to the source code or Discord community for further help/information.
    ;