const std = @import("std");
const Allocator = std.mem.Allocator;

const glib = @import("glib");

const apprt = @import("../../../apprt.zig");
const DBus = @import("DBus.zig");

// Use a D-Bus method call to open a new tab on GTK.
// See: https://wiki.gnome.org/Projects/GLib/GApplication/DBusAPI
//
// `ghostty +new-tab` is equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate new-tab '[<@(tas) (0, [])>]' []
// ```
//
// `ghostty +new-tab -e echo hello` would be equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate new-tab '[<@(tas) (0, ["-e" "echo" "hello"])>]' []
// ```
pub fn newTab(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.NewTab) (Allocator.Error || std.Io.Writer.Error || apprt.ipc.Errors)!bool {
    var dbus = try DBus.init(alloc, target, "new-tab");
    defer dbus.deinit(alloc);

    const tas_variant_type = glib.VariantType.new("(tas)");
    defer tas_variant_type.free();

    var parameter: glib.VariantBuilder = undefined;
    parameter.init(tas_variant_type);
    errdefer parameter.clear();

    {
        // Add the target surface ID to the parameter.
        const t = glib.Variant.newUint64(value.surface_id);
        parameter.addValue(t);
    }

    {
        // If any arguments were specified on the command line, this value is an
        // array of strings that contain the arguments. They will be sent to the
        // main Ghostty instance and interpreted as CLI arguments.
        const as_variant_type = glib.VariantType.new("as");
        defer as_variant_type.free();

        const s_variant_type = glib.VariantType.new("s");
        defer s_variant_type.free();

        var command: glib.VariantBuilder = undefined;
        command.init(as_variant_type);
        errdefer command.clear();

        if (value.arguments) |arguments| {
            for (arguments) |argument| {
                const bytes = glib.Bytes.new(argument.ptr, argument.len + 1);
                defer bytes.unref();
                const string = glib.Variant.newFromBytes(s_variant_type, bytes, @intFromBool(true));
                command.addValue(string);
            }
        }

        parameter.addValue(command.end());
    }

    dbus.addParameter(parameter.end());

    try dbus.send();

    return true;
}
