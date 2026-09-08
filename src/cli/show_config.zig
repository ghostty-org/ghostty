const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const Action = @import("ghostty.zig").Action;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const Key = Config.Key;
const Pager = @import("Pager.zig");
const global = @import("../global.zig");

pub const Options = struct {
    /// Only include this options in the output.
    _filter: ?std.EnumSet(Key) = null,

    /// If true, do not load the user configuration, only load the defaults.
    default: bool = false,

    /// Only show the options that have been changed from the default.
    /// This has no effect if `--default` is specified.
    @"changes-only": bool = true,

    /// If true print the documentation above each option as a comment,
    /// if available.
    docs: bool = false,

    /// Disable automatic paging of output.
    @"no-pager": bool = false,

    pub fn deinit(self: Options) void {
        _ = self;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }

    pub const ParseManuallyHookError = error{};

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as
    ///     option name filter entries and stop parsing.
    ///   - Otherwise, return true for the generic parser to handle.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) ParseManuallyHookError!bool {
        _ = alloc;

        if (!std.mem.eql(u8, arg, "--")) return true;

        var empty = true;
        var filter: std.EnumSet(Key) = .empty;
        while (iter.next()) |next| {
            // Ignore entries that are empty or whitespace-only.
            const trimmed = std.mem.trim(u8, next, " \t");
            if (trimmed.len == 0) continue;

            empty = false;
            const key = std.meta.stringToEnum(Key, trimmed) orelse continue;
            filter.insert(key);
        }
        self._filter = if (empty) null else filter;
        return false;
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
/// You can filter the output by passing a list of option names after `--`.
/// Invalid option names are silently ignored; if none of the given names
/// match, nothing is printed.
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
///
///   * `--no-pager`: Disable automatic paging of output.
pub fn run(alloc: Allocator) !u8 {
    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc, global.args());
        defer iter.deinit();
        try args.parse(Options, alloc, &opts, &iter);
    }

    // Fast path in case of no matching options.
    if (opts._filter) |f| if (f.count() == 0) return 0;

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const configfmt: configpkg.FileFormatter = .{
        .alloc = alloc,
        .config = &config,
        .filter = opts._filter,
        .changed = !opts.default and opts.@"changes-only",
        .docs = opts.docs,
    };

    var pager: Pager = if (!opts.@"no-pager") .init() else .{};
    defer pager.deinit();
    var buffer: [4096]u8 = undefined;
    const writer = pager.writer(&buffer);

    try configfmt.format(writer);
    try writer.flush();
    return 0;
}
