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

/// The `+toggle-quick-terminal` command will use native platform IPC to toggle
/// the quick terminal in a running instance of Ghostty.
///
/// If the `--class` flag is not set, the command will try and connect to the
/// default running Ghostty instance. Otherwise it will contact a Ghostty
/// instance configured with the given `class`.
///
/// On GTK, D-Bus activation must be properly configured. Ghostty does not need
/// to be running, as D-Bus will handle launching a new instance if it is not
/// already running.
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
        error.IPCFailed => {
            return 1;
        },
        else => {
            try stderr.print("Sending the IPC failed: {}\n", .{err});
            return 1;
        },
    }) return 0;

    try stderr.print("+toggle-quick-terminal is not supported on this platform.\n", .{});
    return 1;
}
