const std = @import("std");
const c = @import("../c.zig");
const CoreApp = @import("../../../App.zig");

const log = std.log.scoped(.gtk_dbus);

const UserData = struct {
    core_app: *CoreApp,
    dbus_connection: *c.DBusConnection,
};

pub fn requestBackgroundStart(core_app: *CoreApp, dbus_connection: *c.GDBusConnection) !void {
    const name = c.g_dbus_connection_get_unique_name(dbus_connection);
    log.info("dbus connection unique name: {s}", .{name});

    const sender = try core_app.alloc.dupe(u8, std.mem.span(name)[1..]);
    defer core_app.alloc.free(sender);
    std.mem.replaceScalar(u8, sender, '.', '_');

    var buf: [128]u8 = undefined;
    const handle = try std.fmt.bufPrintZ(&buf, "/org/freedesktop/portal/desktop/request/{s}/ghostty_background_{d}", .{ sender, std.crypto.random.int(u32) });
    log.info("handle: {s}", .{handle});

    _ = c.g_dbus_connection_signal_subscribe(
        dbus_connection,
        null,
        "org.freedesktop.portal.Request",
        "Response",
        &buf,
        null,
        c.G_DBUS_SIGNAL_FLAGS_NONE,
        &requestBackgroundResult,
        core_app,
        null,
    );

    const options = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{sv}"));
    defer c.g_variant_builder_unref(options);

    c.g_variant_builder_add(options, "{sv}", "handle_token", c.g_variant_new("s", "background"));
    c.g_variant_builder_add(options, "{sv}", "reason", c.g_variant_new("s", "because we're cool"));
    c.g_variant_builder_add(options, "{sv}", "autostart", c.g_variant_new("b", @as(u32, 0)));

    const command = c.g_variant_builder_new(c.G_VARIANT_TYPE("as"));
    defer c.g_variant_builder_unref(command);
    c.g_variant_builder_add(command, "s", "ghostty");

    c.g_variant_builder_add(options, "{sv}", "commandline", c.g_variant_builder_end(command));
    c.g_variant_builder_add(options, "{sv}", "dbus-activatable", c.g_variant_new("b", @as(u32, 0)));

    const params = c.g_variant_new(
        "(s@a{sv})",
        "",
        c.g_variant_builder_end(options),
    );
    _ = c.g_variant_ref_sink(params);
    defer c.g_variant_unref(params);

    c.g_dbus_connection_call(
        dbus_connection, // connection
        "org.freedesktop.portal.Desktop", // bus name
        "/org/freedesktop/portal/desktop", // object path
        "org.freedesktop.portal.Background", // interface name
        "RequestBackground", // method name
        params, // parameters
        null,
        // c.G_VARIANT_TYPE("(o)"), // reply type
        c.G_DBUS_CALL_FLAGS_NONE, // flags
        -1, // timeout_msec
        null, // cancellable
        requestBackgroundFinish,
        @ptrCast(dbus_connection),
    );
}

fn requestBackgroundFinish(source_object: ?*c.GObject, res: ?*c.GAsyncResult, user_data: ?*anyopaque) callconv(.C) void {
    _ = source_object;
    const dbus_connection: *c.GDBusConnection = @ptrCast(@alignCast(user_data orelse unreachable));

    var err: ?*c.GError = null;
    defer if (err) |e| c.g_error_free(e);

    const value = c.g_dbus_connection_call_finish(
        dbus_connection,
        res,
        &err,
    ) orelse {
        if (err) |e| log.err("unable to request background: {s}", .{e.message});
        return;
    };
    defer c.g_variant_unref(value);

    log.err("return type: {s}", .{c.g_variant_get_type_string(value)});

    if (c.g_variant_is_of_type(value, c.G_VARIANT_TYPE("(o)")) != 1) {
        log.err("wrong return type: {s}", .{c.g_variant_get_type_string(value)});
        return;
    }

    var path: ?[*c]u8 = null;
    c.g_variant_get(value, "(o)", &path);
    defer if (path) |p| c.g_free(p);

    if (path) |p| {
        log.warn("background path: {s}", .{p});
    } else {
        log.warn("error with path", .{});
    }
}

fn requestBackgroundResult(
    _: ?*c.GDBusConnection,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    _: [*c]const u8,
    parameters: ?*c.GVariant,
    user_data: ?*anyopaque,
) callconv(.C) void {
    _ = parameters;
    _ = user_data;

    log.info("request background result", .{});
}
