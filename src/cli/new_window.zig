const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, open up a new window in a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// If `-e` is found in the arguments, this will contain all of the
    /// arguments to pass to Ghostty as the command.
    _arguments: ?[][:0]const u8 = null,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook, used to deal with `-e`
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) Allocator.Error!bool {
        // If it's not `-e` continue with the standard argument parsning.
        if (!std.mem.eql(u8, arg, "-e")) return true;

        var arguments: std.ArrayListUnmanaged([:0]const u8) = .empty;
        errdefer {
            for (arguments.items) |argument| alloc.free(argument);
            arguments.deinit(alloc);
        }

        // Otherwise gather up the rest of the arguments to use as the command.
        while (iter.next()) |param| {
            try arguments.append(alloc, try alloc.dupeZ(u8, param));
        }

        self._arguments = try arguments.toOwnedSlice(alloc);

        return false;
    }

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
/// If the `--class` flag is not set, the `new-window` command will try and
/// connect to a running instance of Ghostty based on what optimizations the
/// Ghostty CLI was compiled with. Otherwise the `new-window` command will try
/// and contact a running Ghostty instance that was configured with the same
/// `class` as was given on the command line.
///
/// If the `-e` flag is included on the command line, any arguments that follow
/// will be sent to the running Ghostty instance and used as the command to run
/// in the new window rather than the default. If `-e` is not specified, Ghostty
/// will use the default command (either specified with `command` in your config
/// or your default shell as configured on your system).
///
/// GTK uses an application ID to identify instances of applications. If Ghostty
/// is compiled with release optimizations, the default application ID will be
/// `com.mitchellh.ghostty`. If Ghostty is compiled with debug optimizations,
/// the default application ID will be `com.mitchellh.ghostty-debug`.  The
/// `class` configuration entry can be used to set up a custom application
/// ID. The class name must follow the requirements defined [in the GTK
/// documentation](https://docs.gtk.org/gio/type_func.Application.id_is_valid.html)
/// or it will be ignored and Ghostty will use the default as defined above.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running for this to open a new window, making it suitable for binding
/// to keys in your window manager (if other methods for configuring global
/// shortcuts are unavailable). D-Bus will handle launching a new instance
/// of Ghostty if it is not already running. See the Ghostty website for
/// information on properly configuring D-Bus activation.
///
/// Only supported on GTK.
///
/// Flags:
///
///   * `--class=<class>`: If set, open up a new window in a custom instance of
///     Ghostty. The class must be a valid GTK application ID.
///
///   * `-e`: Any arguments after this will be interpreted as a command to
///     execute inside the new window instead of the default command.
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

    if (opts._arguments) |arguments| {
        if (arguments.len == 0) {
            try stderr.print("The -e flag was specified on the command line, but no other arguments were found.\n", .{});
            return 1;
        }
    }

    var arena = ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    if (apprt.App.performIpc(
        alloc,
        if (opts.class) |class| .{ .class = class } else .detect,
        .new_window,
        .{
            .arguments = opts._arguments,
        },
    ) catch |err| switch (err) {
        error.IPCFailed => {
            // The apprt should have printed a more specific error message
            // already.
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}", .{err});
            return 1;
        },
    }) return 0;

    // If we get here, the platform is not supported.
    try stderr.print("+new-window is not supported on this platform.\n", .{});
    return 1;
}
