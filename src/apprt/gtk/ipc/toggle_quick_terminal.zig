const std = @import("std");
const Allocator = std.mem.Allocator;

const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");

/// Use a D-Bus method call to toggle the quick terminal on GTK.
///
/// `ghostty +toggle-quick-terminal` is equivalent to the following command
/// (on a release build):
///
/// ```sh
/// gdbus call --session \
///   --dest com.mitchellh.ghostty \
///   --object-path /com/mitchellh/ghostty \
///   --method org.gtk.Actions.Activate \
///   toggle-quick-terminal [] []
/// ```
pub fn toggleQuickTerminal(alloc: Allocator, target: apprt.ipc.Target) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(alloc, target, "toggle-quick-terminal");
    defer dbus.deinit(alloc);
    try dbus.send();
    return true;
}
