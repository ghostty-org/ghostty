const GlobalShortcuts = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const App = @import("App.zig");
const configpkg = @import("../../config.zig");
const Binding = @import("../../input.zig").Binding;
const key = @import("key.zig");

const log = std.log.scoped(.global_shortcuts);
const Token = [16]u8;

app: *App,
arena: std.heap.ArenaAllocator,
dbus: *gio.DBusConnection,

/// A mapping from a unique ID to an action.
/// Currently the unique ID is simply the serialized representation of the
/// trigger that was used for the action as triggers are unique in the keymap,
/// but this may change in the future.
map: std.StringArrayHashMapUnmanaged(Binding.Action) = .{},

/// The handle of the current global shortcuts portal session,
/// as a D-Bus object path.
handle: ?[:0]const u8 = null,

/// The D-Bus signal subscription for the response signal on requests.
/// The ID is guaranteed to be non-zero, so we can use 0 to indicate null.
response_subscription: c_uint = 0,

/// The D-Bus signal subscription for the keybind activate signal.
/// The ID is guaranteed to be non-zero, so we can use 0 to indicate null.
activate_subscription: c_uint = 0,

pub fn init(alloc: Allocator, gio_app: *gio.Application) ?GlobalShortcuts {
    const dbus = gio_app.getDbusConnection() orelse return null;

    return .{
        // To be initialized later
        .app = undefined,
        .arena = .init(alloc),
        .dbus = dbus,
    };
}

pub fn deinit(self: *GlobalShortcuts) void {
    self.close();
    self.arena.deinit();
}

fn close(self: *GlobalShortcuts) void {
    if (self.response_subscription != 0) {
        self.dbus.signalUnsubscribe(self.response_subscription);
        self.response_subscription = 0;
    }

    if (self.activate_subscription != 0) {
        self.dbus.signalUnsubscribe(self.activate_subscription);
        self.activate_subscription = 0;
    }

    if (self.handle) |handle| {
        // Close existing session
        self.dbus.call(
            "org.freedesktop.portal.Desktop",
            handle,
            "org.freedesktop.portal.Session",
            "Close",
            null,
            null,
            .{},
            -1,
            null,
            null,
            null,
        );
        self.handle = null;
    }
}

pub fn refreshSession(self: *GlobalShortcuts, app: *App) !void {
    // Ensure we have a valid reference to the app
    // (it was left uninitialized in `init`)
    self.app = app;

    // Close any existing sessions
    self.close();

    // Update map
    var trigger_buf: [256]u8 = undefined;

    self.map.clearRetainingCapacity();
    var it = self.app.config.keybind.set.bindings.iterator();

    while (it.next()) |entry| {
        const leaf = switch (entry.value_ptr.*) {
            // Global shortcuts can't have leaders
            .leader => continue,
            .leaf => |leaf| leaf,
        };
        if (!leaf.flags.global) continue;

        const trigger = try key.xdgShortcutFromTrigger(
            &trigger_buf,
            entry.key_ptr.*,
        ) orelse continue;

        try self.map.put(
            self.arena.allocator(),
            try self.arena.allocator().dupeZ(u8, trigger),
            leaf.action,
        );
    }

    if (self.map.count() > 0) {
        try self.request(.create_session);
    }
}

fn shortcutActivated(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *GlobalShortcuts = @ptrCast(@alignCast(ud));

    // 2nd value in the tuple is the activated shortcut ID
    // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-activated
    var shortcut_id: [*:0]const u8 = undefined;
    params.getChild(1, "&s", &shortcut_id);
    log.debug("activated={s}", .{shortcut_id});

    const action = self.map.get(std.mem.span(shortcut_id)) orelse return;

    self.app.core_app.performAllAction(self.app, action) catch |err| {
        log.err("failed to perform action={}", .{err});
    };
}

const Method = enum {
    create_session,
    bind_shortcuts,

    fn name(self: Method) [:0]const u8 {
        return switch (self) {
            .create_session => "CreateSession",
            .bind_shortcuts => "BindShortcuts",
        };
    }

    /// Construct the payload expected by the XDG portal call.
    fn makePayload(
        self: Method,
        shortcuts: *GlobalShortcuts,
        request_token: [:0]const u8,
    ) ?*glib.Variant {
        switch (self) {
            // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-createsession
            .create_session => {
                var session_token: Token = undefined;
                return glib.Variant.newParsed(
                    "({'handle_token': <%s>, 'session_handle_token': <%s>},)",
                    request_token.ptr,
                    generateToken(&session_token).ptr,
                );
            },
            // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-bindshortcuts
            .bind_shortcuts => {
                const handle = shortcuts.handle orelse return null;

                const bind_type = glib.VariantType.new("a(sa{sv})");
                defer glib.free(bind_type);

                var binds: glib.VariantBuilder = undefined;
                glib.VariantBuilder.init(&binds, bind_type);

                var action_buf: [256]u8 = undefined;

                var it = shortcuts.map.iterator();
                while (it.next()) |entry| {
                    const trigger = entry.key_ptr.*.ptr;
                    const action = std.fmt.bufPrintZ(
                        &action_buf,
                        "{}",
                        .{entry.value_ptr.*},
                    ) catch continue;

                    binds.addParsed(
                        "(%s, {'description': <%s>, 'preferred_trigger': <%s>})",
                        trigger,
                        action.ptr,
                        trigger,
                    );
                }

                return glib.Variant.newParsed(
                    "(%o, %*, '', {'handle_token': <%s>})",
                    handle.ptr,
                    binds.end(),
                    request_token.ptr,
                );
            },
        }
    }

    fn onResponse(self: Method, shortcuts: *GlobalShortcuts, vardict: *glib.Variant) void {
        switch (self) {
            .create_session => {
                var handle: ?[*:0]u8 = null;
                if (vardict.lookup("session_handle", "&s", &handle) == 0) {
                    log.err(
                        "session handle not found in response={s}",
                        .{vardict.print(@intFromBool(true))},
                    );
                    return;
                }

                shortcuts.handle = shortcuts.arena.allocator().dupeZ(u8, std.mem.span(handle.?)) catch {
                    log.err("out of memory: failed to clone session handle", .{});
                    return;
                };

                log.debug("session_handle={?s}", .{handle});

                // Subscribe to keybind activations
                shortcuts.activate_subscription = shortcuts.dbus.signalSubscribe(
                    null,
                    "org.freedesktop.portal.GlobalShortcuts",
                    "Activated",
                    "/org/freedesktop/portal/desktop",
                    handle,
                    .{ .match_arg0_path = true },
                    shortcutActivated,
                    shortcuts,
                    null,
                );

                shortcuts.request(.bind_shortcuts) catch |err| {
                    log.err("failed to bind shortcuts={}", .{err});
                    return;
                };
            },
            .bind_shortcuts => {},
        }
    }
};

/// Submit a request to the global shortcuts portal.
fn request(
    self: *GlobalShortcuts,
    comptime method: Method,
) !void {
    // NOTE(pluiedev):
    // XDG Portals are really, really poorly-designed pieces of hot garbage.
    // How the protocol is _initially_ designed to work is as follows:
    //
    // 1. The client calls a method which returns the path of a Request object;
    // 2. The client waits for the Response signal under said object path;
    // 3. When the signal arrives, the actual return value and status code
    //    become available for the client for further processing.
    //
    // THIS DOES NOT WORK. Once the first two steps are complete, the client
    // needs to immediately start listening for the third step, but an overeager
    // server implementation could easily send the Response signal before the
    // client is even ready, causing communications to break down over a simple
    // race condition/two generals' problem that even _TCP_ had figured out
    // decades ago. Worse yet, you get exactly _one_ chance to listen for the
    // signal, or else your communication attempt so far has all been in vain.
    //
    // And they know this. Instead of fixing their freaking protocol, they just
    // ask clients to manually construct the expected object path and subscribe
    // to the request signal beforehand, making the whole response value of
    // the original call COMPLETELY MEANINGLESS.
    //
    // Furthermore, this is _entirely undocumented_ aside from one tiny
    // paragraph under the documentation for the Request interface, and
    // anyone would be forgiven for missing it without reading the libportal
    // source code.
    //
    // When in Rome, do as the Romans do, I guess...?

    const callbacks = struct {
        fn gotResponseHandle(
            source: ?*gobject.Object,
            res: *gio.AsyncResult,
            _: ?*anyopaque,
        ) callconv(.c) void {
            const dbus_ = gobject.ext.cast(gio.DBusConnection, source.?).?;

            var err: ?*glib.Error = null;
            defer if (err) |err_| err_.free();

            const params_ = dbus_.callFinish(res, &err) orelse {
                if (err) |err_| log.err("request failed={s} ({})", .{
                    err_.f_message orelse "(unknown)",
                    err_.f_code,
                });
                return;
            };
            defer params_.unref();

            // TODO: XDG recommends updating the signal subscription if the actual
            // returned request path is not the same as the expected request
            // path, to retain compatibility with older versions of XDG portals.
            // Although it suffers from the race condition outlined above,
            // we should still implement this at some point.
        }

        // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html#org-freedesktop-portal-request-response
        fn responded(
            dbus: *gio.DBusConnection,
            _: ?[*:0]const u8,
            _: [*:0]const u8,
            _: [*:0]const u8,
            _: [*:0]const u8,
            params_: *glib.Variant,
            ud: ?*anyopaque,
        ) callconv(.c) void {
            const self_: *GlobalShortcuts = @ptrCast(@alignCast(ud));

            // Unsubscribe from the response signal
            if (self_.response_subscription != 0) {
                dbus.signalUnsubscribe(self_.response_subscription);
                self_.response_subscription = 0;
            }

            var response: u32 = 0;
            var vardict: ?*glib.Variant = null;
            params_.get("(u@a{sv})", &response, &vardict);

            switch (response) {
                0 => {
                    log.debug("request successful", .{});
                    method.onResponse(self_, vardict.?);
                },
                1 => log.debug("request was cancelled by user", .{}),
                2 => log.warn("request ended unexpectedly", .{}),
                else => log.err("unrecognized response code={}", .{response}),
            }
        }
    };

    var request_token_buf: Token = undefined;
    const request_token = generateToken(&request_token_buf);

    const payload = method.makePayload(self, request_token) orelse return;
    const request_path = try self.getRequestPath(request_token);

    self.response_subscription = self.dbus.signalSubscribe(
        null,
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        null,
        .{},
        callbacks.responded,
        self,
        null,
    );

    self.dbus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.GlobalShortcuts",
        method.name(),
        payload,
        null,
        .{},
        -1,
        null,
        callbacks.gotResponseHandle,
        null,
    );
}

/// Generate a random token suitable for use in requests.
fn generateToken(buf: *Token) [:0]const u8 {
    // u28 takes up 7 bytes in hex, 8 bytes for "ghostty_" and 1 byte for NUL
    // 7 + 8 + 1 = 16
    return std.fmt.bufPrintZ(
        buf,
        "ghostty_{x:0<7}",
        .{std.crypto.random.int(u28)},
    ) catch unreachable;
}

/// Get the XDG portal request path for the current Ghostty instance.
///
/// If this sounds like nonsense, see `request` for an explanation as to
/// why we need to do this.
fn getRequestPath(self: *GlobalShortcuts, token: [:0]const u8) ![:0]const u8 {
    // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html
    // for the syntax XDG portals expect.

    // `getUniqueName` should never return null here as we're using an ordinary
    // message bus connection. If it doesn't, something is very wrong
    const unique_name = std.mem.span(self.dbus.getUniqueName().?);

    const object_path = try std.mem.joinZ(self.arena.allocator(), "/", &.{
        "/org/freedesktop/portal/desktop/request",
        unique_name[1..], // Remove leading `:`
        token,
    });

    // Sanitize the unique name by replacing every `.` with `_`.
    // In effect, this will turn a unique name like `:1.192` into `1_192`.
    // Valid D-Bus object path components never contain `.`s anyway, so we're
    // free to replace all instances of `.` here and avoid extra allocation.
    std.mem.replaceScalar(u8, object_path, '.', '_');

    return object_path;
}
