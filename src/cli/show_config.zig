const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

pub const Options = struct {
    /// If true, do not load the user configuration, only load the defaults.
    default: bool = false,

    /// Only show the options that have been changed from the default.
    /// This has no effect if `--default` is specified.
    @"changes-only": bool = true,

    /// If true print the documentation above each option as a comment,
    /// if available.
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

/// The `show-config` command shows the current configuration in a valid Ghostty
/// configuration file format.
///
/// When executed without any arguments this will output the current
/// configuration that is different from the default configuration. If you're
/// using the default configuration this will output nothing.
///
/// If you are a new user and want to see all available options with
/// documentation, run `ghostty +show-config --default --docs`.
///
/// The output is not in any specific order, but the order should be consistent
/// between runs. The output is not guaranteed to be exactly match the input
/// configuration files, but it will result in the same behavior. Comments,
/// whitespace, and other formatting is not preserved from user configuration
/// files.
///
/// Flags:
///
///   * `--default`: Show the default configuration instead of loading
///     the user configuration.
///
///   * `--changes-only`: Only show the options that have been changed
///     from the default. This has no effect if `--default` is specified.
///
///   * `--docs`: Print the documentation above each option as a comment,
///     This is very noisy but is very useful to learn about available
///     options, especially paired with `--default`.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc);
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const configfmt: configpkg.FileFormatter = .{
        .alloc = alloc,
        .config = &config,
        .changed = !opts.default and opts.@"changes-only",
        .docs = opts.docs,
    };

    // For some reason `std.fmt.format` isn't working here but it works in
    // tests so we just do configfmt.format.
    const stdout = std.io.getStdOut().writer();
    try configfmt.format("", .{}, stdout);
    return 0;
}
