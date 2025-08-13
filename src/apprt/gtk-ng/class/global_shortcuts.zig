const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Binding = @import("../../../input.zig").Binding;
const gresource = @import("../build/gresource.zig");
const key = @import("../key.zig");
const Common = @import("../class.zig").Common;
const Application = @import("application.zig").Application;
const Config = @import("config.zig").Config;

const log = std.log.scoped(.gtk_ghostty_global_shortcuts);

pub const GlobalShortcuts = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = gobject.Object;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyGlobalShortcuts",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const @"dbus-connection" = struct {
            pub const name = "dbus-connection";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*gio.DBusConnection,
                .{
                    .accessor = C.privateObjFieldAccessor("dbus_connection"),
                },
            );
        };
    };

    const Private = struct {
        /// The configuration that this is using.
        config: ?*Config = null,

        /// The dbus connection.
        dbus_connection: ?*gio.DBusConnection = null,

        /// An arena allocator that is present for each refresh.
        arena: ?std.heap.ArenaAllocator = null,

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

        pub var offset: c_int = 0;
    };

    pub const signals = struct {
        /// Emitted whenever a global shortcut is triggered.
        pub const trigger = struct {
            pub const name = "trigger";
            pub const connect = impl.connect;
            const impl = gobject.ext.defineSignal(
                name,
                Self,
                &.{*const Binding.Action},
                void,
            );
        };
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        _ = gobject.Object.signals.notify.connect(
            self,
            *Self,
            propConfig,
            self,
            .{ .detail = "config" },
        );
    }

    fn close(self: *Self) void {
        const priv = self.private();
        const dbus = priv.dbus_connection orelse return;

        if (priv.response_subscription != 0) {
            dbus.signalUnsubscribe(priv.response_subscription);
            priv.response_subscription = 0;
        }

        if (priv.activate_subscription != 0) {
            dbus.signalUnsubscribe(priv.activate_subscription);
            priv.activate_subscription = 0;
        }

        if (priv.handle) |handle| {
            // Close existing session
            dbus.call(
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
            priv.handle = null;
        }

        if (priv.arena) |*arena| {
            arena.deinit();
            priv.arena = null;
            priv.map = .{}; // Uses arena memory
        }
    }

    fn refresh(self: *Self) Allocator.Error!void {
        // Always close our previous state first.
        self.close();

        const priv = self.private();

        // We need configuration to proceed.
        const config = if (priv.config) |v| v.get() else return;

        // Setup our new arena that we'll use for memory allocations.
        assert(priv.arena == null);
        var arena: std.heap.ArenaAllocator = .init(Application.default().allocator());
        errdefer arena.deinit();
        const alloc = arena.allocator();

        // Our map starts out empty again. We don't need to worry about
        // memory because its part of the arena we clear.
        priv.map = .{};
        errdefer priv.map = .{};

        // Update map
        var trigger_buf: [1024]u8 = undefined;
        var it = config.keybind.set.bindings.iterator();
        while (it.next()) |entry| {
            const leaf = switch (entry.value_ptr.*) {
                // Global shortcuts can't have leaders
                .leader => continue,
                .leaf => |leaf| leaf,
            };
            if (!leaf.flags.global) continue;

            const trigger = if (key.xdgShortcutFromTrigger(
                &trigger_buf,
                entry.key_ptr.*,
            )) |shortcut_|
                shortcut_ orelse continue
            else |err| switch (err) {
                // If there isn't space to translate the trigger, then our
                // buffer might be too small (but 1024 is insane!). In any case
                // we don't want to stop registering globals.
                error.NoSpaceLeft => {
                    log.warn(
                        "buffer too small to translate trigger, ignoring={}",
                        .{entry.key_ptr.*},
                    );
                    continue;
                },
            };

            try priv.map.put(
                alloc,
                try alloc.dupeZ(u8, trigger),
                leaf.action,
            );
        }

        // Store our arena
        priv.arena = arena;

        // Create our session if we have global shortcuts.
        if (priv.map.count() > 0) try self.request(.create_session);
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
                    const priv = shortcuts.private();
                    const handle = priv.handle orelse return null;

                    const bind_type = glib.VariantType.new("a(sa{sv})");
                    defer glib.free(bind_type);

                    var binds: glib.VariantBuilder = undefined;
                    glib.VariantBuilder.init(&binds, bind_type);

                    var action_buf: [256]u8 = undefined;

                    var it = priv.map.iterator();
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
                        log.warn(
                            "session handle not found in response={s}",
                            .{vardict.print(@intFromBool(true))},
                        );
                        return;
                    }

                    const priv = shortcuts.private();
                    const dbus = priv.dbus_connection.?;
                    const alloc = priv.arena.?.allocator();
                    priv.handle = alloc.dupeZ(u8, std.mem.span(handle.?)) catch {
                        log.warn("out of memory: failed to clone session handle", .{});
                        return;
                    };
                    log.debug("session_handle={?s}", .{handle});

                    // Subscribe to keybind activations
                    assert(priv.activate_subscription == 0);
                    priv.activate_subscription = dbus.signalSubscribe(
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
                        log.warn("failed to bind shortcuts={}", .{err});
                        return;
                    };
                },
                .bind_shortcuts => {},
            }
        }
    };

    /// Submit a request to the global shortcuts portal.
    fn request(
        self: *Self,
        comptime method: Method,
    ) Allocator.Error!void {
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
                    if (err) |err_| log.warn("request failed={s} ({})", .{
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
                const self_cb: *GlobalShortcuts = @ptrCast(@alignCast(ud));
                const priv = self_cb.private();

                // Unsubscribe from the response signal
                if (priv.response_subscription != 0) {
                    dbus.signalUnsubscribe(priv.response_subscription);
                    priv.response_subscription = 0;
                }

                var response: u32 = 0;
                var vardict: ?*glib.Variant = null;
                defer if (vardict) |v| v.unref();
                params_.get("(u@a{sv})", &response, &vardict);

                switch (response) {
                    0 => {
                        log.debug("request successful", .{});
                        method.onResponse(self_cb, vardict.?);
                    },
                    1 => log.debug("request was cancelled by user", .{}),
                    2 => log.warn("request ended unexpectedly", .{}),
                    else => log.warn("unrecognized response code={}", .{response}),
                }
            }
        };

        var request_token_buf: Token = undefined;
        const request_token = generateToken(&request_token_buf);

        const payload = method.makePayload(self, request_token) orelse return;
        const request_path = try self.getRequestPath(request_token);

        const priv = self.private();
        const dbus = priv.dbus_connection.?;

        assert(priv.response_subscription == 0);
        priv.response_subscription = dbus.signalSubscribe(
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

        dbus.call(
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

    /// Get the XDG portal request path for the current Ghostty instance.
    ///
    /// If this sounds like nonsense, see `request` for an explanation as to
    /// why we need to do this.
    ///
    /// Precondition: dbus connection exists, arena setup
    fn getRequestPath(self: *Self, token: [:0]const u8) Allocator.Error![:0]const u8 {
        const priv = self.private();
        const dbus = priv.dbus_connection.?;
        const alloc = priv.arena.?.allocator();

        // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html
        // for the syntax XDG portals expect.

        // `getUniqueName` should never return null here as we're using an ordinary
        // message bus connection. If it doesn't, something is very wrong
        const unique_name = std.mem.span(dbus.getUniqueName().?);

        const object_path = try std.mem.joinZ(
            alloc,
            "/",
            &.{
                "/org/freedesktop/portal/desktop/request",
                unique_name[1..], // Remove leading `:`
                token,
            },
        );

        // Sanitize the unique name by replacing every `.` with `_`.
        // In effect, this will turn a unique name like `:1.192` into `1_192`.
        // Valid D-Bus object path components never contain `.`s anyway, so we're
        // free to replace all instances of `.` here and avoid extra allocation.
        std.mem.replaceScalar(u8, object_path, '.', '_');

        return object_path;
    }

    //---------------------------------------------------------------
    // Property Handlers

    pub fn setDbusConnection(
        self: *Self,
        dbus_connection: ?*gio.DBusConnection,
    ) void {
        const priv = self.private();

        // If we have a prior dbus connection we need to close our prior
        // registrations first.
        if (priv.dbus_connection) |v| {
            self.close();
            v.unref();
            priv.dbus_connection = null;
        }

        priv.dbus_connection = null;
        if (dbus_connection) |v| {
            v.ref(); // Weird this doesn't return self
            priv.dbus_connection = v;
            self.refresh() catch |err| {
                log.warn("error refreshing global shortcuts: {}", .{err});
            };
        }

        self.as(gobject.Object).notifyByPspec(properties.@"dbus-connection".impl.param_spec);
    }

    fn propConfig(
        _: *Self,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.refresh() catch |err| {
            log.warn("error refreshing global shortcuts: {}", .{err});
        };
    }

    //---------------------------------------------------------------
    // Signal Handlers

    fn shortcutActivated(
        _: *gio.DBusConnection,
        _: ?[*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        _: [*:0]const u8,
        params: *glib.Variant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud));

        // 2nd value in the tuple is the activated shortcut ID
        // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.GlobalShortcuts.html#org-freedesktop-portal-globalshortcuts-activated
        var shortcut_id: [*:0]const u8 = undefined;
        params.getChild(1, "&s", &shortcut_id);
        log.debug("activated={s}", .{shortcut_id});

        const action = self.private().map.get(std.mem.span(shortcut_id)) orelse return;
        signals.trigger.impl.emit(
            self,
            null,
            .{&action},
            null,
        );
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        // Since we drop references here we may lose access to things like
        // dbus connections, so we need to close all our connections right
        // away instead of in finalize.
        self.close();

        const priv = self.private();
        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }
        if (priv.dbus_connection) |v| {
            v.unref();
            priv.dbus_connection = null;
        }

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.config.impl,
                properties.@"dbus-connection".impl,
            });

            // Signals
            signals.trigger.impl.register(.{});

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
    };
};

const Token = [16]u8;

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
