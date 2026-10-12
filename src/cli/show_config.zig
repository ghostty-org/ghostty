const std = @import("std");
const args = @import("args.zig");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("ghostty.zig").Action;
const configpkg = @import("../config.zig");
const Config = configpkg.Config;
const Key = Config.Key;
const diagnostics = @import("diagnostics.zig");
const Pager = @import("Pager.zig");
const global = @import("../global.zig");

pub const Options = struct {
    /// Set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// Only include these options in the output, or all of them if null.
    _include: ?std.EnumSet(Key) = null,

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

    /// Errors found in the arguments, both before and after `--`.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables `-h` and `--help` to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }

    pub const ParseManuallyHookError = Allocator.Error;

    /// Manual parse hook. For each argument:
    ///   - If it's a literal `--`, consume everything after it as
    ///     names of options to include and stop parsing. Unknown
    ///     names and misplaced flags are recorded as diagnostics.
    ///   - Otherwise, return true for the generic parser to handle.
    pub fn parseManuallyHook(
        self: *Options,
        alloc: Allocator,
        arg: []const u8,
        iter: anytype,
    ) ParseManuallyHookError!bool {
        if (!std.mem.eql(u8, arg, "--")) return true;

        var requested = false;
        var include: std.EnumSet(Key) = .empty;

        while (iter.next()) |next| {
            // Ignore arguments that are empty or whitespace-only.
            const trimmed = std.mem.trim(u8, next, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            requested = true;

            // A bare `--` is treated as an option name.
            if (std.mem.cutPrefix(u8, trimmed, "--")) |rest| {
                if (rest.len > 0) {
                    const flag = std.mem.sliceTo(rest, '=');

                    try self._diagnostics.append(alloc, .{
                        .location = try .fromIter(iter, alloc),
                        .key = try alloc.dupeSentinel(u8, flag, 0),
                        .message = "flags must come before `--`",
                    });
                    continue;
                }
            }
            const key = std.meta.stringToEnum(Key, trimmed) orelse {
                try self._diagnostics.append(alloc, .{
                    .location = try .fromIter(iter, alloc),
                    .key = try alloc.dupeSentinel(u8, trimmed, 0),
                    .message = "unknown configuration option",
                });
                continue;
            };
            include.insert(key);
        }
        self._include = if (requested) include else null;
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
/// To show only specific options, list them after a `--` separator, for example
/// `ghostty +show-config -- font-family font-size`. Everything after the
/// separator is treated as an option name, so flags such as `--default` must
/// come before it. Unknown names and misplaced flags are reported as errors.
/// The other flags still apply to the listed options, so with `--changes-only`
/// (the default) an option that is set to its default value is not printed.
///
/// The output is not in any specific order, but the order should be consistent
/// between runs. The output is not guaranteed to exactly match the input
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
///   * `--docs`: Print the documentation above each option as a comment.
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

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (!opts._diagnostics.empty()) {
        for (opts._diagnostics.items()) |diag| {
            try stderr.print("Error: {f}\n", .{diag});
        }
        try stderr_writer.flush();
        return 1;
    }

    var config = if (opts.default) try Config.default(alloc) else try Config.load(alloc);
    defer config.deinit();

    const configfmt: configpkg.FileFormatter = .{
        .alloc = alloc,
        .config = &config,
        .include = opts._include,
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

fn parseTestArgs(alloc: Allocator, opts: *Options, line: []const u8) !void {
    var it: std.process.Args.IteratorGeneral(.{}) = try .init(alloc, line);
    defer it.deinit();
    try args.parse(Options, alloc, opts, &it);
}

test "parseManuallyHook: no names include all options" {
    {
        var opts: Options = .{};
        defer opts.deinit();
        try parseTestArgs(std.testing.allocator, &opts, "--docs --default");

        try std.testing.expect(opts._include == null);
        try std.testing.expect(opts._diagnostics.empty());
    }
    {
        var opts: Options = .{};
        defer opts.deinit();
        try parseTestArgs(std.testing.allocator, &opts, "-- \" \t\r\n\"");

        try std.testing.expect(opts._include == null);
        try std.testing.expect(opts._diagnostics.empty());
    }
}

test "parseManuallyHook: unknown names include nothing" {
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(std.testing.allocator, &opts, "-- broken-option");

    try std.testing.expect(opts._include.?.count() == 0);
    try std.testing.expect(!opts._diagnostics.empty());
}

test "parseManuallyHook: included names are trimmed and deduplicated" {
    var opts: Options = .{ .default = false };
    defer opts.deinit();
    try parseTestArgs(
        std.testing.allocator,
        &opts,
        "--default -- font-size \" font-family\n\" font-size",
    );

    try std.testing.expect(opts.default);
    try std.testing.expect(opts._diagnostics.empty());

    const include = opts._include.?;
    try std.testing.expect(include.count() == 2);
    try std.testing.expect(include.contains(.@"font-size"));
    try std.testing.expect(include.contains(.@"font-family"));
}

test "parseManuallyHook: unknown option name" {
    var opts: Options = .{};
    defer opts.deinit();
    try parseTestArgs(std.testing.allocator, &opts, "-- font-size font-sise --");

    try std.testing.expect(opts._include.?.contains(.@"font-size"));

    const diags = opts._diagnostics.items();
    try std.testing.expect(diags.len == 2);

    try std.testing.expectEqualStrings("font-sise", diags[0].key);
    try std.testing.expectEqualStrings("unknown configuration option", diags[0].message);

    try std.testing.expectEqualStrings("--", diags[1].key);
    try std.testing.expectEqualStrings("unknown configuration option", diags[1].message);
}

test "parseManuallyHook: flag after separator" {
    var opts: Options = .{ .default = false };
    defer opts.deinit();
    try parseTestArgs(
        std.testing.allocator,
        &opts,
        "-- font-size --default=true --=foo",
    );

    try std.testing.expect(!opts.default);

    const diags = opts._diagnostics.items();
    try std.testing.expect(diags.len == 2);

    try std.testing.expectEqualStrings("default", diags[0].key);
    try std.testing.expectEqualStrings("flags must come before `--`", diags[0].message);

    try std.testing.expectEqualStrings("", diags[1].key);
    try std.testing.expectEqualStrings("flags must come before `--`", diags[1].message);
}
