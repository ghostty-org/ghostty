const std = @import("std");
const args = @import("args.zig");
const Action = @import("action.zig").Action;
const Allocator = std.mem.Allocator;
const helpgen_actions = @import("../input/helpgen_actions.zig");

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
    try helpgen_actions.generate(stdout, .plaintext, opts.docs, std.heap.page_allocator);

    return 0;
}
