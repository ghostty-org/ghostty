//! Sends and clears desktop notifications associated with a single GTK surface.
//! Access this object only on the GTK main thread and keep its address stable
//! until deinit has cancelled its timers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const gio = @import("gio");
const glib = @import("glib");

const DesktopNotifications = @This();
const log = std.log.scoped(.gtk_desktop_notifications);

const default_limit = 64;
// Match macOS: notifications sent while focused expire after three seconds.
const focused_timeout_ms = 3 * std.time.ms_per_s;

/// Notification content used for lookup. Stored keys own copies of both
/// strings; temporary lookup keys borrow the caller's strings.
const Key = struct {
    title: []const u8,
    body: []const u8,

    fn clone(self: Key, alloc: Allocator) Allocator.Error!Key {
        const title = try alloc.dupe(u8, self.title);
        errdefer alloc.free(title);
        const body = try alloc.dupe(u8, self.body);
        return .{ .title = title, .body = body };
    }

    fn deinit(self: Key, alloc: Allocator) void {
        alloc.free(self.title);
        alloc.free(self.body);
    }

    fn hash(self: Key) u64 {
        var hasher = std.hash.Wyhash.init(0);
        hasher.update(self.title);
        hasher.update("\x00");
        hasher.update(self.body);
        return hasher.final();
    }

    fn eql(self: Key, other: Key) bool {
        return std.mem.eql(u8, self.title, other.title) and
            std.mem.eql(u8, self.body, other.body);
    }
};

const Notification = struct {
    timeout_source: ?c_uint = null,
};

const TrackResult = struct {
    // Borrows the stored key until the entry is removed or the manager cleared.
    key: Key,
    evicted: ?Notifications.KV = null,
};

/// GLib callback data. The manager and application must outlive the source.
/// The key borrows stored strings; external cleanup must cancel the source
/// before freeing them.
const Timeout = struct {
    alloc: Allocator,
    notifications: *DesktopNotifications,
    app: *gio.Application,
    key: Key,
};

/// Hash and compare string contents rather than the addresses of their slices.
const Context = struct {
    pub fn hash(_: Context, key: Key) u32 {
        return @truncate(key.hash());
    }

    pub fn eql(_: Context, a: Key, b: Key, _: usize) bool {
        return a.eql(b);
    }
};

const Notifications = std.ArrayHashMapUnmanaged(
    Key,
    Notification,
    Context,
    true,
);

/// Entries are ordered from oldest to newest; replacement refreshes their age.
notifications: Notifications = .empty,
/// Bound on the first send and retained for later withdrawal, even after clear.
surface_id: u64 = 0,
/// Bound retained entries because GIO does not report desktop-side dismissals.
limit: usize,

/// Create an empty manager. Call this explicitly when initializing a GObject:
/// zeroed private memory does not apply Zig field defaults.
pub fn init() DesktopNotifications {
    return .{ .limit = default_limit };
}

/// Send or replace a notification for this surface. Content is copied, so the
/// caller may release title and body on return. Use the same application and
/// allocator for all sends and cleanup calls on this manager.
pub fn send(
    self: *DesktopNotifications,
    alloc: Allocator,
    app: *gio.Application,
    surface_id: u64,
    focused: bool,
    title: [:0]const u8,
    body: [:0]const u8,
) void {
    assert(surface_id != 0);
    if (self.surface_id == 0) {
        self.surface_id = surface_id;
    } else {
        assert(self.surface_id == surface_id);
    }

    const display_title = if (title.len == 0) "Ghostty" else title;
    const notification = gio.Notification.new(display_title);
    defer notification.unref();
    notification.setBody(body);

    const icon = gio.ThemedIcon.new("com.mitchellh.ghostty");
    defer icon.unref();
    notification.setIcon(icon.as(gio.Icon));
    notification.setDefaultActionAndTargetValue(
        "app.present-surface",
        glib.Variant.newUint64(surface_id),
    );

    const tracked = self.track(alloc, title, body) catch |err| {
        log.warn("unable to track desktop notification err={}", .{err});
        return;
    };
    if (tracked.evicted) |evicted| self.clearRemoved(alloc, app, evicted);

    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, surface_id, tracked.key);
    app.sendNotification(id, notification);

    if (focused) self.scheduleTimeout(alloc, app, tracked.key);
}

/// Withdraw delivered notifications and cancel their timers. GIO's freedesktop
/// backend cannot withdraw a notification until its asynchronous Notify reply
/// arrives. A notification still in flight may therefore outlive this call.
pub fn clear(
    self: *DesktopNotifications,
    alloc: Allocator,
    app: *gio.Application,
) void {
    while (self.pop()) |removed| self.clearRemoved(alloc, app, removed);
    self.notifications.clearAndFree(alloc);
}

/// Store content and return any evicted entry for withdrawal by the caller.
fn track(
    self: *DesktopNotifications,
    alloc: Allocator,
    title: []const u8,
    body: []const u8,
) Allocator.Error!TrackResult {
    const key: Key = .{ .title = title, .body = body };
    if (self.notifications.fetchOrderedRemove(key)) |removed| {
        // Keep the owned strings and move the entry to the newest position.
        cancelTimeout(removed.value.timeout_source);
        self.notifications.putAssumeCapacity(removed.key, .{});
        return .{ .key = removed.key };
    }

    // Complete allocations before eviction so failure preserves existing entries.
    const stored_key = try key.clone(alloc);
    errdefer stored_key.deinit(alloc);

    var evicted: ?Notifications.KV = null;
    if (self.notifications.count() >= self.limit) {
        evicted = self.pop();
    } else {
        try self.notifications.ensureUnusedCapacity(alloc, 1);
    }

    self.notifications.putAssumeCapacity(stored_key, .{});
    return .{ .key = stored_key, .evicted = evicted };
}

/// Remove the oldest entry, transferring its key and timer to the caller.
fn pop(self: *DesktopNotifications) ?Notifications.KV {
    if (self.notifications.count() == 0) return null;
    return self.notifications.fetchOrderedRemove(self.notifications.keys()[0]);
}

/// Cancel the removed entry's timer and withdraw it before freeing its key.
fn clearRemoved(
    self: *DesktopNotifications,
    alloc: Allocator,
    app: *gio.Application,
    removed: Notifications.KV,
) void {
    cancelTimeout(removed.value.timeout_source);
    self.withdraw(app, removed.key);
    removed.key.deinit(alloc);
}

fn withdraw(
    self: *DesktopNotifications,
    app: *gio.Application,
    key: Key,
) void {
    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, self.surface_id, key);
    app.withdrawNotification(id);
}

fn scheduleTimeout(
    self: *DesktopNotifications,
    alloc: Allocator,
    app: *gio.Application,
    key: Key,
) void {
    const notification = self.notifications.getPtr(key) orelse return;
    cancelTimeout(notification.timeout_source);
    notification.timeout_source = null;

    const timeout = alloc.create(Timeout) catch |err| {
        log.warn("unable to allocate desktop notification timer err={}", .{err});
        return;
    };
    timeout.* = .{
        .alloc = alloc,
        .notifications = self,
        .app = app,
        .key = key,
    };
    notification.timeout_source = glib.timeoutAddFull(
        glib.PRIORITY_DEFAULT,
        focused_timeout_ms,
        timeoutCallback,
        timeout,
        timeoutDestroy,
    );
}

fn timeoutCallback(ud: ?*anyopaque) callconv(.c) c_int {
    const timeout: *Timeout = @ptrCast(@alignCast(ud orelse
        return @intFromBool(glib.SOURCE_REMOVE)));
    const removed = timeout.notifications.notifications.fetchOrderedRemove(timeout.key) orelse
        return @intFromBool(glib.SOURCE_REMOVE);
    assert(removed.value.timeout_source != null);
    // This source is already dispatching. Let SOURCE_REMOVE destroy its callback
    // data after return instead of cancelling it through clearRemoved.
    timeout.notifications.withdraw(timeout.app, removed.key);
    removed.key.deinit(timeout.alloc);
    return @intFromBool(glib.SOURCE_REMOVE);
}

fn timeoutDestroy(ud: ?*anyopaque) callconv(.c) void {
    const timeout: *Timeout = @ptrCast(@alignCast(ud orelse return));
    timeout.alloc.destroy(timeout);
}

fn cancelTimeout(source_: ?c_uint) void {
    const source = source_ orelse return;
    if (glib.Source.remove(source) == 0) {
        log.warn("unable to remove desktop notification timer", .{});
    }
}

/// Release notifications, timers, and storage. Safe after clear or deinit.
pub fn deinit(self: *DesktopNotifications, alloc: Allocator, app: *gio.Application) void {
    self.clear(alloc, app);
}

/// GIO requires the same ID for sending and withdrawing. Including the surface
/// ID keeps identical notifications from different surfaces independent.
/// The fixed buffer fits the prefix, two 16-digit hex values, and a terminator.
fn formatId(
    buf: *[64]u8,
    surface_id: u64,
    key: Key,
) [:0]u8 {
    return std.fmt.bufPrintZ(
        buf,
        "ghostty-surface-{x}-{x}",
        .{ surface_id, key.hash() },
    ) catch unreachable;
}

test "desktop notification IDs are stable per surface and content" {
    const testing = std.testing;

    const first: Key = .{ .title = "Title", .body = "Body" };
    const repeated: Key = .{ .title = "Title", .body = "Body" };
    const other_title: Key = .{ .title = "Other", .body = "Body" };
    const other_body: Key = .{ .title = "Title", .body = "Other" };

    var first_buf: [64]u8 = undefined;
    const surface_id = std.math.maxInt(u64);
    const first_id = formatId(&first_buf, surface_id, first);
    var repeated_buf: [64]u8 = undefined;
    const repeated_id = formatId(&repeated_buf, surface_id, repeated);
    var other_surface_buf: [64]u8 = undefined;
    const other_surface_id = formatId(&other_surface_buf, 2, first);
    var other_title_buf: [64]u8 = undefined;
    const other_title_id = formatId(&other_title_buf, surface_id, other_title);
    var other_body_buf: [64]u8 = undefined;
    const other_body_id = formatId(&other_body_buf, surface_id, other_body);

    try testing.expectEqualStrings(first_id, repeated_id);
    try testing.expect(!std.mem.eql(u8, first_id, other_surface_id));
    try testing.expect(!std.mem.eql(u8, first_id, other_title_id));
    try testing.expect(!std.mem.eql(u8, first_id, other_body_id));
}

test "desktop notifications replace and evict oldest" {
    const testing = std.testing;

    var notifications: DesktopNotifications = .{ .limit = 3 };
    defer {
        while (notifications.pop()) |removed| removed.key.deinit(testing.allocator);
        notifications.notifications.deinit(testing.allocator);
    }

    _ = try notifications.track(testing.allocator, "First", "Body");
    _ = try notifications.track(testing.allocator, "Second", "Body");
    _ = try notifications.track(testing.allocator, "Third", "Body");

    const repeated = try notifications.track(testing.allocator, "First", "Body");
    try testing.expectEqual(@as(?c_uint, null), notifications.notifications.getPtr(repeated.key).?.timeout_source);
    try testing.expectEqual(@as(?Notifications.KV, null), repeated.evicted);

    const fourth = try notifications.track(testing.allocator, "Fourth", "Body");
    const evicted = fourth.evicted.?;
    defer evicted.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Second", evicted.key.title);
    try testing.expectEqual(@as(usize, 3), notifications.notifications.count());
}

test "desktop notifications remove and drain independently" {
    const testing = std.testing;

    var first: DesktopNotifications = .init();
    defer {
        while (first.pop()) |removed| removed.key.deinit(testing.allocator);
        first.notifications.deinit(testing.allocator);
    }
    var second: DesktopNotifications = .init();
    defer {
        while (second.pop()) |removed| removed.key.deinit(testing.allocator);
        second.notifications.deinit(testing.allocator);
    }

    const first_notification = try first.track(testing.allocator, "Title", "Body");
    _ = try first.track(testing.allocator, "Other", "Body");
    _ = try second.track(testing.allocator, "Title", "Body");

    const removed = first.notifications.fetchOrderedRemove(first_notification.key).?;
    defer removed.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Title", removed.key.title);
    try testing.expectEqual(@as(usize, 1), first.notifications.count());
    try testing.expectEqual(@as(usize, 1), second.notifications.count());

    const drained = first.pop().?;
    defer drained.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Other", drained.key.title);
    try testing.expectEqual(@as(usize, 0), first.notifications.count());
    try testing.expect(first.pop() == null);
    try testing.expectEqual(@as(usize, 1), second.notifications.count());
}
