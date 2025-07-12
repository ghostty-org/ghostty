const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const Options = @import("../new_window.zig").Options;

// Use a D-Bus method call to open a new window on GTK.
// See: https://wiki.gnome.org/Projects/GLib/GApplication/DBusAPI
pub fn new_window(alloc: Allocator, stderr: std.fs.File.Writer, opts: Options) (Allocator.Error || std.posix.WriteError)!u8 {
    // Get the appropriate bus name and object path for contacting the
    // Ghostty instance we're interested in.
    const bus_name: [:0]const u8, const object_path: [:0]const u8 = result: {
        // Force the usage of the class specified on the CLI to determine the
        // bus name and object path.
        if (opts.class) |class| {
            const object_path = try std.fmt.allocPrintZ(alloc, "/{s}", .{class});

            std.mem.replaceScalar(u8, object_path, '.', '/');
            std.mem.replaceScalar(u8, object_path, '-', '_');

            break :result .{ class, object_path };
        }
        // Force the usage of the release bus name and object path.
        if (opts.release) {
            break :result .{ "com.mitchellh.ghostty", "/com/mitchellh/ghostty" };
        }
        // Force the usage of the debug bus name and object path.
        if (opts.debug) {
            break :result .{ "com.mitchellh.ghostty-debug", "/com/mitchellh/ghostty_debug" };
        }
        // If there is a `GHOSTTY_CLASS` environment variable, use that as the basis
        // for the bus name and object path.
        if (std.posix.getenv("GHOSTTY_CLASS")) |class| {
            const object_path = try std.fmt.allocPrintZ(alloc, "/{s}", .{class});

            std.mem.replaceScalar(u8, object_path, '.', '/');
            std.mem.replaceScalar(u8, object_path, '-', '_');

            break :result .{ class, object_path };
        }
        // Otherwise fall back to the release bus name and object path.
        break :result .{ "com.mitchellh.ghostty", "/com/mitchellh/ghostty" };
    };

    if (gio.Application.idIsValid(bus_name.ptr) == 0) {
        try stderr.print("D-Bus bus name is not valid: {s}\n", .{bus_name});
        return 1;
    }

    if (glib.Variant.isObjectPath(object_path.ptr) == 0) {
        try stderr.print("D-Bus object path is not valid: {s}\n", .{object_path});
        return 1;
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
            return 1;
        }

        break :dbus dbus_ orelse {
            try stderr.print("gio.busGetSync returned null\n", .{});
            return 1;
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
        errdefer builder.unref();

        // action
        builder.add("s", "new-window");

        // parameters
        {
            const parameters = glib.VariantType.new("av");
            defer glib.free(parameters);

            builder.open(parameters);
            defer builder.close();

            // we have no parameters
        }
        {
            const platform_data = glib.VariantType.new("a{sv}");
            defer glib.free(platform_data);

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
            return 1;
        }
    }

    return 0;
}
