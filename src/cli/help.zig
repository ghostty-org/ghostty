const std = @import("std");
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;

// Note that this options struct doesn't implement the `help` decl like other
// actions. That is because the help command is special and wants to handle its
// own logic around help detection.
pub const Options = struct {
    /// This must be registered so that it isn't an error to pass `--help`
    help: bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }
};

/// The `help` command shows general help about Ghostty. Recognized as either
/// `-h, `--help`, or like other actions `+help`.
///
/// You can also specify `--help` or `-h` along with any action such as
/// `+list-themes` to see help for a specific action.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(
        \\Usage: ghostty [+action] [options]
        \\
        \\Run the Ghostty terminal emulator or a specific helper action.
        \\
        \\If no `+action` is specified, run the Ghostty terminal emulator.
        \\All configuration keys are available as command line options.
        \\To specify a configuration key, use the `--<key>=<value>` syntax
        \\where key and value are the same format you'd put into a configuration
        \\file. For example, `--font-size=12` or `--font-family="Fira Code"`.
        \\
        \\To see a list of all available configuration options, please see
        \\the `src/config/Config.zig` file. A future update will allow seeing
        \\the list of configuration options from the command line.
        \\
        \\A special command line argument `-e <command>` can be used to run
        \\the specific command inside the terminal emulator. For example,
        \\`ghostty -e top` will run the `top` command inside the terminal.
        \\
        \\On macOS, launching the terminal emulator from the CLI is not
        \\supported and only actions are supported. Use `open -na Ghostty.app`
        \\instead, or `open -na ghostty.app --args --foo=bar --baz=quz` to pass
        \\arguments.
        \\
        \\Available actions:
        \\
        \\
    );

    inline for (@typeInfo(Action).@"enum".fields) |field| {
        try stdout.print("  +{s}\n", .{field.name});
    }

    try stdout.writeAll(
        \\
        \\Specify `+<action> --help` to see the help for a specific action,
        \\where `<action>` is one of actions listed above.
        \\
    );

    return 0;
}
