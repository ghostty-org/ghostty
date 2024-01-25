const std = @import("std");
const c = @import("c.zig");

const App = @import("App.zig");

const dbus_structs = @import("dbus_structs.zig");

const log = std.log.scoped(.@"gtk-dbus");

pub fn init(app: *App) !void {
    if (!app.config.@"gtk-dbus-integration") return;

    const app_id = c.g_application_get_application_id(@ptrCast(app.app));
    log.warn("app id: {s}", .{app_id});

    const dbus_name_owner_id = c.g_bus_own_name(
        c.G_BUS_TYPE_SESSION,
        app_id,
        0,
        onDBusBusAcquired, // bus acquired callback
        onDBusNameAcquired, // name acquired callback
        onDBusNameLost, // name lost callback
        @ptrCast(app), // user data
        null, // user data free func
    );

    log.warn("g_dbus_own_name: {}", .{dbus_name_owner_id});
}

pub fn deinit(app: *App) !void {
    if (app.dbus_name_owner_id) |id| c.g_bus_unown_name(id);
    if (app.dbus_gnome_shell_search_provider_object_id) |id| _ = c.g_dbus_connection_unregister_object(app.dbus_connection orelse unreachable, id);
}

fn onDBusBusAcquired(
    connection: ?*c.GDBusConnection,
    name: [*c]const u8,
    user_data: c.gpointer,
) callconv(.C) void {
    log.warn("dbus bus acquired: {s}", .{name});

    const app = @as(*App, @ptrCast(@alignCast(user_data)));

    app.dbus_connection = connection orelse {
        log.warn("dbus connection was null", .{});
        return;
    };

    if (app.config.@"gtk-dbus-integration-features".@"gnome-shell-search") enableGnomeShellSearch(app);
    if (app.config.@"gtk-dbus-integration-features".@"background-apps") requestBackground(app);
}

fn onDBusNameAcquired(
    connection: ?*c.GDBusConnection,
    name: [*c]const u8,
    user_data: c.gpointer,
) callconv(.C) void {
    _ = connection;
    _ = user_data;
    log.warn("dbus name acquired: {s}", .{name});
}

fn onDBusNameLost(
    connection: ?*c.GDBusConnection,
    name: [*c]const u8,
    user_data: c.gpointer,
) callconv(.C) void {
    _ = connection;
    _ = user_data;
    log.warn("dbus name lost: {s}", .{name});
}

fn enableGnomeShellSearch(app: *App) void {
    const xml = c.g_string_new(null);

    c.g_dbus_interface_info_generate_xml(&dbus_structs.gnome_shell_search_provider, 2, xml);

    const str = c.g_string_free_and_steal(xml);
    defer c.g_free(str);

    log.debug("{s}", .{str});

    var vtable = c.GDBusInterfaceVTable{
        .method_call = dbusSearchProvider,
        .get_property = null,
        .set_property = null,
    };

    var err: [*c]c.GError = null;

    const id = c.g_dbus_connection_register_object(
        app.dbus_connection orelse unreachable,
        "/com/mitchellh/ghostty/SearchProvider",
        &dbus_structs.gnome_shell_search_provider,
        &vtable,
        @ptrCast(app),
        null,
        &err,
    );
    if (id == 0) {
        log.warn("register object failed: {s}", .{err.*.message});
    } else {
        log.info("register object suceeded!", .{});
        app.dbus_gnome_shell_search_provider_object_id = id;
    }
}

fn dbusSearchProvider(
    connection: ?*c.GDBusConnection,
    sender: [*c]const u8,
    object_path: [*c]const u8,
    interface_name: [*c]const u8,
    method_name: [*c]const u8,
    parameters: ?*c.GVariant,
    invocation: ?*c.GDBusMethodInvocation,
    user_data: c.gpointer,
) callconv(.C) void {
    _ = connection;
    _ = invocation;

    _ = @as(*App, @ptrCast(@alignCast(user_data)));

    log.warn("dbus search provider", .{});
    log.warn("dbus sender        : {s}", .{sender});
    log.warn("dbus object path   : {s}", .{object_path});
    log.warn("dbus interface name: {s}", .{interface_name});
    log.warn("dbus method name   : {s}", .{method_name});

    var iter: *c.GVariantIter = undefined;
    var term: [*c]const u8 = undefined;
    c.g_variant_get(parameters.?, "(as)", &iter);
    defer c.g_variant_iter_free(iter);
    while (c.g_variant_iter_loop(iter, "s", &term) != 0) {
        // defer c.g_free(term);
        log.warn("dbus: search term: {s}", .{term});
    }
}

fn requestBackground(app: *App) void {
    const options_builder = c.g_variant_builder_new(c.G_VARIANT_TYPE("a{sv}"));
    defer c.g_variant_builder_unref(options_builder);

    const params = c.g_variant_new(
        "(s@a{sv})",
        "",
        c.g_variant_builder_end(options_builder),
    );
    _ = c.g_variant_ref_sink(params);
    defer c.g_variant_unref(params);

    c.g_dbus_connection_call(
        app.dbus_connection orelse unreachable, // connection
        "org.freedesktop.portal.Desktop", // bus name
        "/org/freedesktop/portal/desktop", // object path
        "org.freedesktop.portal.Background", // interface name
        "RequestBackground", // method name
        params, // parameters
        c.G_VARIANT_TYPE("(o)"), // reply type
        c.G_DBUS_CALL_FLAGS_NONE, // flags
        -1, // timeout_msec
        null, // cancellable
        requestBackgroundFinished, // callback
        @ptrCast(app), // user data
    );
}

fn requestBackgroundFinished(
    source_object: ?*c.GObject,
    res: ?*c.GAsyncResult,
    user_data: c.gpointer,
) callconv(.C) void {
    _ = source_object;
    const app = @as(*App, @ptrCast(@alignCast(user_data)));
    var err: [*c]c.GError = null;

    const reply = c.g_dbus_connection_call_finish(
        app.dbus_connection orelse unreachable,
        res,
        &err,
    ) orelse {
        log.warn("request background failed: {s}", .{err.*.message});
        return;
    };

    var path: [*c]const u8 = undefined;
    c.g_variant_get(reply, "(o)", &path);
    defer c.g_free(reply);

    if (path) |p| {
        log.warn("background result: {s}", .{p});
    } else {
        log.warn("did background request fail?", .{});
    }
}
