const std = @import("std");
const Allocator = std.mem.Allocator;
const Action = @import("../cli.zig").ghostty.Action;
const apprt = @import("../apprt.zig");
const global = @import("../global.zig");

pub const Options = struct {
    /// If set, connect to a custom instance of Ghostty.
    class: ?[:0]const u8 = null,

    pub fn deinit(self: *Options) void {
        self.* = undefined;
    }

    /// Enables "-h" and "--help" to work.
    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

/// The `+toggle-quick-terminal` command toggles the quick terminal in a
/// running Ghostty instance. If no instance owns the D-Bus name, it launches
/// one directly as a quick terminal.
///
/// Only supported on GTK.
///
/// Flags:
///
///   * `--class=<class>`: If set, connect to a custom instance of Ghostty.
///     The class must be a valid GTK application ID.
///
/// Available since: 1.4.0
pub fn run(alloc: Allocator) !u8 {
    var buf: [256]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(global.io(), &buf);
    const stderr = &stderr_writer.interface;

    if (apprt.App.performIpc(
        alloc,
        .detect,
        .toggle_quick_terminal,
        {},
    ) catch |err| switch (err) {
        error.ServiceNotFound, error.IPCFailed => return launchQuickTerminal(alloc, stderr),
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+toggle-quick-terminal is not supported on this platform.\n", .{});
    return 1;
}

fn launchQuickTerminal(
    alloc: Allocator,
    stderr: *std.Io.Writer,
) !u8 {
    var args = try global.args().iterateAllocator(alloc);
    defer args.deinit();
    const exe_path = args.next() orelse return error.MissingExecutablePath;

    var environ = try global.environMap();
    defer environ.deinit();
    try environ.put("GHOSTTY_LAUNCH_QUICK_TERMINAL", "1");

    _ = std.process.spawn(global.io(), .{
        .argv = &.{exe_path},
        .stdout = .ignore,
        .stderr = .inherit,
        .environ_map = &environ,
    }) catch |err| {
        try stderr.print("Unable to launch quick terminal: {}\n", .{err});
        return 1;
    };
    return 0;
}
