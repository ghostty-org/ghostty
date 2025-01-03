const std = @import("std");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Allocator = std.mem.Allocator;
const help_strings = @import("help_strings");

pub const Options = struct {
    /// If `true`, print out documentation about the action associated with the
    /// keybinds.
    docs: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `list-actions` command is used to list all the available keybind
/// actions for Ghostty. These are distinct from the CLI Actions which can
/// be listed via `+help`
///
/// Flags:
///
///   * `--docs`: will print out the documentation for each action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    const info = @typeInfo(help_strings.KeybindAction);
    inline for (info.Struct.decls) |field| {
        try stdout.print("{s}", .{field.name});
        if (opts.docs) {
            try stdout.print(":\n", .{});
            var iter = std.mem.splitScalar(u8, std.mem.trimRight(u8, @field(help_strings.KeybindAction, field.name), &std.ascii.whitespace), '\n');
            while (iter.next()) |line| {
                try stdout.print("  {s}\n", .{line});
            }
        } else {
            try stdout.print("\n", .{});
        }
    }

    return 0;
}
