//! Use DBus to call the XDG Desktop Portal to open an URI.
//! See: https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.OpenURI.html#org-freedesktop-portal-openuri-openuri
const OpenURI = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");

const App = @import("../App.zig");
const portal = @import("../portal.zig");
const apprt = @import("../../../apprt.zig");

const log = std.log.scoped(.openuri);

/// The GTK app that we "belong" to.
app: *App,

/// Connection to the D-Bus session bus that we'll use for all of our messaging.
dbus: *gio.DBusConnection,

/// Mutex to protect modification of the entries map or the cleanup timer.
mutex: std.Thread.Mutex = .{},

/// Map to store data about any in-flight calls to the portal.
entries: std.AutoHashMapUnmanaged(usize, Entry) = .empty,

/// Used to manage a timer to clean up any orphan entries in the map.
cleanup_timer: ?c_uint = null,

/// Data about any in-flight calls to the portal.
pub const Entry = struct {
    /// When the request started.
    start: std.time.Instant,
    /// A token used by the portal to identify requests and responses. The actual
    /// format of the token does not really matter as long as it can be used as
    /// part of a D-Bus object path. `usize` was chosen since it's easy to hash and
    /// to generate random tokens.
    token: usize,
    /// The "kind" of URI. Unused here, but we may need to pass it on to the fallback
    /// URL opener if the D-Bus method fails.
    kind: apprt.action.OpenUrl.Kind,
    /// A copy of the URI that we are opening. We need our own copy since the method
    /// calls are asynchronous and the original may have been freed by the time we need
    /// it.
    uri: [:0]const u8,
    /// Used to manage a scription to a D-Bus signal, which is how the Portal
    /// reports results of the method call.
    subscription: ?c_uint = null,

    pub fn deinit(self: *Entry, alloc: Allocator) void {
        alloc.free(self.uri);
    }
};

pub const Errors = error{
    DBusConnectionRequired,
    NoDBusUniqueName,
    PutFailed,
};

pub fn init(
    self: *OpenURI,
    app: *App,
) error{DBusConnectionRequired}!void {
    const gio_app = app.app.as(gio.Application);
    const dbus = gio_app.getDbusConnection() orelse {
        return error.DBusConnectionRequired;
    };

    self.* = .{
        .app = app,
        .dbus = dbus,
    };
}

/// Send the D-Bus method call to the XDG Desktop portal. The result of the
/// method call will be reported asynchronously.
pub fn start(self: *OpenURI, value: apprt.action.OpenUrl) (Allocator.Error || Errors)!void {
    const alloc = self.app.core_app.alloc;

    const token = portal.generateToken();

    self.mutex.lock();
    defer self.mutex.unlock();

    try self.entries.putNoClobber(alloc, token, .{
        .start = std.time.Instant.now() catch @panic("can't get the current time!"),
        .token = token,
        .kind = value.kind,
        .uri = try alloc.dupeZ(u8, value.url),
    });

    const entry = self.entries.getPtr(token) orelse {
        return error.PutFailed;
    };

    self.startCleanupTimer();

    try self.subscribeToResponse(entry);
    try self.sendRequest(entry);
}

pub fn deinit(self: *OpenURI) void {
    const alloc = self.app.core_app.alloc;

    var it = self.entries.valueIterator();
    while (it.next()) |value| {
        value.deinit(alloc);
    }

    self.entries.deinit(alloc);
}

/// Subscribe to the D-Bus signal that will contain the results of our method
/// call to the portal. This must be called with the mutex locked.
fn subscribeToResponse(self: *OpenURI, entry: *Entry) (Allocator.Error || Errors)!void {
    const alloc = self.app.core_app.alloc;

    if (entry.subscription != null) return;

    const request_path = try portal.getRequestPath(alloc, self.dbus, entry.token);
    defer alloc.free(request_path);

    entry.subscription = self.dbus.signalSubscribe(
        null,
        "org.freedesktop.portal.Request",
        "Response",
        request_path,
        null,
        .{},
        responseReceived,
        self,
        null,
    );
}
// Unsubscribe to the D-Bus signal that contains the result of the method call.
// This will prevent a response from being processed multiple times. This must
// be called when the mutex is locked.
fn unsubscribeFromResponse(self: *OpenURI, entry: *Entry) void {

    // Unsubscribe from the response signal
    if (entry.subscription) |subscription| {
        self.dbus.signalUnsubscribe(subscription);
        entry.subscription = null;
    }
}

/// Send the D-Bus method call to the portal. The mutex must be locked when this
/// is called.
fn sendRequest(self: *OpenURI, entry: *Entry) Allocator.Error!void {
    const alloc = self.app.core_app.alloc;

    const payload = payload: {
        const builder_type = glib.VariantType.new("(ssa{sv})");
        defer glib.free(builder_type);

        // Initialize our builder to build up our parameters
        var builder: glib.VariantBuilder = undefined;
        builder.init(builder_type);

        // parent window - empty string means we have no window
        builder.add("s", "");

        // URI to open
        builder.add("s", entry.uri.ptr);

        // Options
        {
            const options = glib.VariantType.new("a{sv}");
            defer glib.free(options);

            builder.open(options);
            defer builder.close();

            {
                const option = glib.VariantType.new("{sv}");
                defer glib.free(option);

                builder.open(option);
                defer builder.close();

                builder.add("s", "handle_token");

                const token = try std.fmt.allocPrintZ(alloc, "{x:0<16}", .{entry.token});
                defer alloc.free(token);

                const handle_token = glib.Variant.newString(token.ptr);
                builder.add("v", handle_token);
            }
            {
                const option = glib.VariantType.new("{sv}");
                defer glib.free(option);

                builder.open(option);
                defer builder.close();

                builder.add("s", "writable");

                const writable = glib.Variant.newBoolean(@intFromBool(false));
                builder.add("v", writable);
            }
            {
                const option = glib.VariantType.new("{sv}");
                defer glib.free(option);

                builder.open(option);
                defer builder.close();

                builder.add("s", "ask");

                const ask = glib.Variant.newBoolean(@intFromBool(false));
                builder.add("v", ask);
            }
        }

        break :payload builder.end();
    };

    // We're expecting an object path back from the method call.
    const reply_type = glib.VariantType.new("(o)");
    defer glib.free(reply_type);

    self.dbus.call(
        "org.freedesktop.portal.Desktop",
        "/org/freedesktop/portal/desktop",
        "org.freedesktop.portal.OpenURI",
        "OpenURI",
        payload,
        reply_type,
        .{},
        -1,
        null,
        requestCallback,
        self,
    );
}

/// Process the result of the original method call. Receiving this result does
/// not indicate that the that the method call succeeded but it may contain an
/// error message that is useful to log for debugging purposes.
fn requestCallback(
    _: ?*gobject.Object,
    result: *gio.AsyncResult,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *OpenURI = @ptrCast(@alignCast(ud orelse return));

    var err_: ?*glib.Error = null;
    defer if (err_) |err| err.free();

    const reply_ = self.dbus.callFinish(result, &err_);

    if (err_) |err| {
        log.err("Open URI request failed={s} ({})", .{
            err.f_message orelse "(unknown)",
            err.f_code,
        });
        return;
    }

    const reply = reply_ orelse {
        log.err("D-Bus method call returned a null value!", .{});
        return;
    };
    defer reply.unref();

    const reply_type = glib.VariantType.new("(o)");
    defer glib.free(reply_type);

    if (reply.isOfType(reply_type) == 0) {
        log.warn("Reply from D-Bus method call does not contain an object path!", .{});
        return;
    }

    var object_path_: ?[*:0]const u8 = null;
    reply.get("(o)", &object_path_);

    const object_path = object_path_ orelse {
        log.err("D-Bus method call did not return an object path", .{});
        return;
    };

    const token = portal.parseRequestPath(std.mem.span(object_path)) orelse {
        log.warn("Unable to parse token from the object path {s}", .{object_path});
        return;
    };

    // Check to see if the request path returned matches a token that we sent.
    self.mutex.lock();
    defer self.mutex.unlock();

    if (!self.entries.contains(token)) {
        log.warn("Token {x:0<16} not found in the map!", .{token});
    }
}

/// Handle the response signal from the portal. This should contain the actual
/// results of the method call (success or failure).
fn responseReceived(
    _: *gio.DBusConnection,
    _: ?[*:0]const u8,
    object_path: [*:0]const u8,
    _: [*:0]const u8,
    _: [*:0]const u8,
    params: *glib.Variant,
    ud: ?*anyopaque,
) callconv(.c) void {
    const self: *OpenURI = @ptrCast(@alignCast(ud orelse {
        log.err("OpenURI response received with null userdata", .{});
        return;
    }));

    const alloc = self.app.core_app.alloc;

    const token = portal.parseRequestPath(std.mem.span(object_path)) orelse {
        log.warn("invalid object path: {s}", .{std.mem.span(object_path)});
        return;
    };

    self.mutex.lock();
    defer self.mutex.unlock();

    var entry = (self.entries.fetchRemove(token) orelse {
        log.warn("no entry for token {x:0<16}", .{token});
        return;
    }).value;
    log.warn("removed {x:0<16} from the map", .{entry.token});
    defer entry.deinit(alloc);

    self.unsubscribeFromResponse(&entry);

    var response: u32 = 0;
    var results: ?*glib.Variant = null;
    params.get("(u@a{sv})", &response, &results);

    switch (response) {
        0 => {
            log.debug("open uri successful", .{});
        },
        1 => {
            log.debug("open uri request was cancelled by the user", .{});
        },
        2 => {
            log.warn("open uri request ended unexpectedly", .{});
            self.app.openUrlFallback(entry.kind, entry.uri);
        },
        else => {
            log.err("unrecognized response code={}", .{response});
            self.app.openUrlFallback(entry.kind, entry.uri);
        },
    }
}

/// Wait this number of seconds and then clean up any orphaned entries.
const cleanup_timeout = 30;

// this must be called with the mutex locked
fn stopCleanupTimer(self: *OpenURI) void {
    if (self.cleanup_timer) |timer| {
        if (glib.Source.remove(timer) == 0) {
            log.warn("unable to remove cleanup timer source={d}", .{timer});
        }
        self.cleanup_timer = null;
    }
}

// this must be called with the mutex locked
fn startCleanupTimer(self: *OpenURI) void {
    self.stopCleanupTimer();
    self.cleanup_timer = glib.timeoutAddSeconds(cleanup_timeout + 1, cleanup, self);
}

/// The cleanup timer is used to free up any entries that may have failed
/// to get a response in a timely manner.
fn cleanup(ud: ?*anyopaque) callconv(.c) c_int {
    const self: *OpenURI = @ptrCast(@alignCast(ud orelse {
        log.warn("cleanup called with null userdata", .{});
        return @intFromBool(glib.SOURCE_REMOVE);
    }));

    self.mutex.lock();
    defer self.mutex.unlock();

    self.cleanup_timer = null;

    const now = std.time.Instant.now() catch @panic("unable to get time!");

    var it = self.entries.valueIterator();
    while (it.next()) |entry| {
        if (now.since(entry.start) > cleanup_timeout * std.time.ns_per_s) {
            self.unsubscribeFromResponse(entry);
            _ = self.entries.remove(entry.token);
        }
    }

    return @intFromBool(glib.SOURCE_REMOVE);
}
