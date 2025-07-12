const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const build_config = @import("../build_config.zig");
const Action = @import("../cli.zig").ghostty.Action;
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const Config = configpkg.Config;

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If `true`, open up a new window in a release instance of Ghostty.
    release: bool = false,

    /// If `true`, open up a new window in a debug instance of Ghostty.
    debug: bool = false,

    /// If set, open up a new window in a custom instance of Ghostty. Takes
    /// precedence over `--debug`.
    class: ?[:0]const u8 = null,

    // Enable arg parsing diagnostics so that we don't get an error if
    // there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    pub fn deinit(self: *Options) void {
        if (self._arena) |arena| arena.deinit();
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `new-window` will use native platform IPC to open up a new window in a
/// running instance of Ghostty.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running for this to open a new window, making it suitable for binding
/// to keys in your window manager (if other methods for configuring global
/// shortcuts are unavailable). D-Bus will handle launching a new instance
/// of Ghostty if it is not already running. See the Ghostty website for
/// information on properly configuring D-Bus activation.
///
/// GTK uses an application ID to identify instances of applications. If
/// Ghostty is compiled with debug optimizations, the application ID will
/// be `com.mitchellh.ghostty-debug`. If Ghostty is compiled with release
/// optimizations, the application ID will be `com.mitchellh.ghostty`.
///
/// The `class` configuration entry can be used to set up a custom application
/// ID. The class name must follow the requirements defined [in the GTK
/// documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html)
/// or it will be ignored and Ghostty will use the default application ID as
/// defined above.
///
/// The `new-window` command will try and find the application ID of the running
/// Ghostty instance in the `GHOSTTY_CLASS` environment variable. If this
/// environment variable is not set, and any of the command line flags defined
/// below are not set, a release instance of Ghostty will be opened.
///
/// Only supported on GTK.
///
/// Flags:
///
///   * `--release`:  If `true`, force opening up a new window in a release instance of
///     Ghostty.
///
///   * `--debug`:  If `true`, force opening up a new window in a debug instance of
///     Ghostty.
///
///   * `--class=<class>`: If set, open up a new window in a custom instance of Ghostty. The
///     class must be a valid GTK application ID.
///
/// Available since: 1.2.0
pub fn run(alloc: Allocator) !u8 {
    var iter = try args.argsIterator(alloc);
    defer iter.deinit();
    return try runArgs(alloc, &iter);
}

fn runArgs(alloc_gpa: Allocator, argsIter: anytype) !u8 {
    const stderr = std.io.getStdErr().writer();

    var opts: Options = .{};
    defer opts.deinit();

    args.parse(Options, alloc_gpa, &opts, argsIter) catch |err| switch (err) {
        error.ActionHelpRequested => return err,
        else => {
            try stderr.print("Error parsing args: {}\n", .{err});
            return 1;
        },
    };

    // Print out any diagnostics, unless it's likely that the diagnostic was
    // generated trying to parse a "normal" configuration setting. Exit with an
    // error code if any diagnostics were printed.
    if (!opts._diagnostics.empty()) {
        var exit: bool = false;
        outer: for (opts._diagnostics.items()) |diagnostic| {
            if (diagnostic.location != .cli) continue :outer;
            inner: inline for (@typeInfo(Options).@"struct".fields) |field| {
                if (field.name[0] == '_') continue :inner;
                if (std.mem.eql(u8, field.name, diagnostic.key)) {
                    try stderr.writeAll("config error: ");
                    try diagnostic.write(stderr);
                    try stderr.writeAll("\n");
                    exit = true;
                }
            }
        }
        if (exit) return 1;
    }

    var count: usize = 0;
    if (opts.release) count += 1;
    if (opts.debug) count += 1;
    if (opts.class) |_| count += 1;

    if (count > 1) {
        try stderr.print("The --release, --debug, and --class flags are mutually exclusive, only one may be specified at a time.\n", .{});
        return 1;
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (comptime build_config.app_runtime == .gtk) {
        const new_window = @import("new_window/gtk.zig").new_window;
        return try new_window(alloc, stderr, opts);
    }

    // If we get here, the platform is unsupported.
    try stderr.print("+new-window is unsupported on this platform\n", .{});
    return 1;
}
