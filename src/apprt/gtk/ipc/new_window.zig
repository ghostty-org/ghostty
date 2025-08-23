const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const apprt = @import("../../../apprt.zig");

// Use a D-Bus method call to open a new window on GTK.
// See: https://wiki.gnome.org/Projects/GLib/GApplication/DBusAPI
//
// `ghostty +new-window` is equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate new-window [] []
// ```
//
// `ghostty +new-window -e echo hello` would be equivalent to the following command (on a release build):
//
// ```
// gdbus call --session --dest com.mitchellh.ghostty --object-path /com/mitchellh/ghostty --method org.gtk.Actions.Activate new-window-command '[<@as ["echo" "hello"]>]' []
// ```
pub fn openNewWindow(alloc: Allocator, target: apprt.ipc.Target, value: apprt.ipc.Action.NewWindow) (Allocator.Error || std.posix.WriteError || apprt.ipc.Errors)!bool {
    const stderr = std.io.getStdErr().writer();

    // Get the appropriate bus name and object path for contacting the
    // Ghostty instance we're interested in.
    const bus_name: [:0]const u8, const object_path: [:0]const u8 = switch (target) {
        .class => |class| result: {
            // Force the usage of the class specified on the CLI to determine the
            // bus name and object path.
            const object_path = try std.fmt.allocPrintZ(alloc, "/{s}", .{class});

            std.mem.replaceScalar(u8, object_path, '.', '/');
            std.mem.replaceScalar(u8, object_path, '-', '_');

            break :result .{ class, object_path };
        },
        .detect => switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ "com.mitchellh.ghostty-debug", "/com/mitchellh/ghostty_debug" },
            .ReleaseFast, .ReleaseSmall => .{ "com.mitchellh.ghostty", "/com/mitchellh/ghostty" },
        },
    };
    defer {
        switch (target) {
            .class => alloc.free(object_path),
            .detect => {},
        }
    }

    if (gio.Application.idIsValid(bus_name.ptr) == 0) {
        try stderr.print("D-Bus bus name is not valid: {s}\n", .{bus_name});
        return error.IPCFailed;
    }

    if (glib.Variant.isObjectPath(object_path.ptr) == 0) {
        try stderr.print("D-Bus object path is not valid: {s}\n", .{object_path});
        return error.IPCFailed;
    }

    const dbus = dbus: {
        var err_: ?*glib.Error = null;
        defer if (err_) |err| err.free();

        const dbus_ = gio.busGetSync(.session, null, &err_);
        if (err_) |err| {
            try stderr.print(
                "Unable to establish connection to D-Bus session bus: {s}\n",
                .{err.f_message orelse "(unknown)"},
            );
            return error.IPCFailed;
        }

        break :dbus dbus_ orelse {
            try stderr.print("gio.busGetSync returned null\n", .{});
            return error.IPCFailed;
        };
    };
    defer dbus.unref();

    // use a builder to create the D-Bus method call payload
    const payload = payload: {
        const builder_type = glib.VariantType.new("(sava{sv})");
        defer glib.free(builder_type);

        // Initialize our builder to build up our parameters
        var builder: glib.VariantBuilder = undefined;
        builder.init(builder_type);
        errdefer builder.clear();

        // action
        if (value.arguments == null) {
            builder.add("s", "new-window");
        } else {
            builder.add("s", "new-window-command");
        }

        // parameters
        {
            const av = glib.VariantType.new("av");
            defer av.free();

            var parameters: glib.VariantBuilder = undefined;
            parameters.init(av);
            errdefer parameters.clear();

            if (value.arguments) |arguments| {
                // If `-e` was specified on the command line, the first
                // parameter is an array of strings that contain the arguments
                // that came after `-e`, which will be interpreted as a command
                // to run.
                {
                    const as = glib.VariantType.new("as");
                    defer as.free();

                    var command: glib.VariantBuilder = undefined;
                    command.init(as);
                    errdefer command.clear();

                    for (arguments) |argument| {
                        command.add("s", argument.ptr);
                    }

                    parameters.add("v", command.end());
                }
            }

            builder.addValue(parameters.end());
        }

        {
            const platform_data = glib.VariantType.new("a{sv}");
            defer platform_data.free();

            builder.open(platform_data);
            defer builder.close();

            // we have no platform data
        }

        break :payload builder.end();
    };

    {
        var err_: ?*glib.Error = null;
        defer if (err_) |err| err.free();

        const result_ = dbus.callSync(
            bus_name,
            object_path,
            "org.gtk.Actions",
            "Activate",
            payload,
            null, // We don't care about the return type, we don't do anything with it.
            .{}, // no flags
            -1, // default timeout
            null, // not cancellable
            &err_,
        );
        defer if (result_) |result| result.unref();

        if (err_) |err| {
            try stderr.print(
                "D-Bus method call returned an error err={s}\n",
                .{err.f_message orelse "(unknown)"},
            );
            return error.IPCFailed;
        }
    }

    return true;
}
