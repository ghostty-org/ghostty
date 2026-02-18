const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const args = @import("args.zig");
const diagnostics = @import("diagnostics.zig");
const lib = @import("../lib/main.zig");
const homedir = @import("../os/homedir.zig");

pub const Options = struct {
    /// This is set by the CLI parser for deinit.
    _arena: ?ArenaAllocator = null,

    /// If set, open up a new window in a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    /// All of the arguments after `+new-window`. They will be sent to Ghosttty
    /// for processing.
    _arguments: ?[][:0]const u8 = null,

    /// Enable arg parsing diagnostics so that we don't get an error if
    /// there is a "normal" config setting on the cli.
    _diagnostics: diagnostics.DiagnosticList = .{},

    /// Manual parse hook, collect all of the arguments after `+new-window`.
    pub fn parseManuallyHook(self: *Options, alloc: Allocator, arg: []const u8, iter: anytype) (error{InvalidValue} || homedir.ExpandError || std.fs.Dir.RealPathAllocError || Allocator.Error)!bool {
        var arguments: std.ArrayList([:0]const u8) = .empty;
        errdefer {
            for (arguments.items) |argument| alloc.free(argument);
            arguments.deinit(alloc);
        }

        var e_seen: bool = std.mem.eql(u8, arg, "-e");
        // Include the argument that triggered the manual parse hook.
        if (try self.checkArg(alloc, arg)) |a| try arguments.append(alloc, a);

        // Gather up the rest of the arguments to use as the command.
        while (iter.next()) |param| {
            if (e_seen) {
                try arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (std.mem.eql(u8, param, "-e")) {
                e_seen = true;
                try arguments.append(alloc, try alloc.dupeZ(u8, param));
                continue;
            }
            if (try self.checkArg(alloc, param)) |a| try arguments.append(alloc, a);
        }

        self._arguments = try arguments.toOwnedSlice(alloc);

        return false;
    }

    fn checkArg(self: *Options, alloc: Allocator, arg: []const u8) (error{InvalidValue} || homedir.ExpandError || std.fs.Dir.RealPathAllocError || Allocator.Error)!?[:0]const u8 {
        if (lib.cutPrefix(u8, arg, "--class=")) |rest| {
            self.class = try alloc.dupeZ(u8, std.mem.trim(u8, rest, &std.ascii.whitespace));
            return null;
        }

        if (lib.cutPrefix(u8, arg, "--working-directory=")) |rest| {
            const stripped = std.mem.trim(u8, rest, &std.ascii.whitespace);
            if (std.mem.eql(u8, stripped, "home")) return error.InvalidValue;
            if (std.mem.eql(u8, stripped, "inherit")) return error.InvalidValue;
            const cwd: std.fs.Dir = std.fs.cwd();
            var expandhome_buf: [std.fs.max_path_bytes]u8 = undefined;
            const expanded = try homedir.expandHome(stripped, &expandhome_buf);
            var realpath_buf: [std.fs.max_path_bytes]u8 = undefined;
            const realpath = try cwd.realpath(expanded, &realpath_buf);
            return try std.fmt.allocPrintSentinel(alloc, "--working-directory={s}", .{realpath}, 0);
        }

        return try alloc.dupeZ(u8, arg);
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
/// All of the arguments after the `+new-window` argument (except for the
/// `--class` flag) will be sent to the remote Ghostty instance and will be
/// parsed as command line flags. These flags will override certain settings
/// when creating the first surface in the new window. Currently, only
/// `--working-directory` and `--command` are supported. `-e` will also work
/// as an alias for `--command`, except that if `-e` is found on the command
/// line all following arguments will become part of the command and no more
/// arguments will be parsed for configuration settings.
///
/// If `--working-directory` is found on the command line and is a relative
/// path (i.e. doesn't start with `/`) it will be resolved to an absolute path
/// relative to the current working directory that the `ghostty +new-window`
/// command is run from. The special values `home` and `inherit` that are
/// available as "normal" CLI flags or configuration entries do not work when
/// used from the `+new-window` CLI action.
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

    var buffer: [1024]u8 = undefined;
    var stderr_writer = std.fs.File.stderr().writer(&buffer);
    const stderr = &stderr_writer.interface;

    const result = runArgs(alloc, &iter, stderr);
    stderr.flush() catch {};
    return result;
}

fn runArgs(
    alloc_gpa: Allocator,
    argsIter: anytype,
    stderr: *std.Io.Writer,
) !u8 {
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
                    try stderr.print("config error: {f}\n", .{diagnostic});
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
