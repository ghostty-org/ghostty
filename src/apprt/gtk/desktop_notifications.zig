//! Sends and clears desktop notifications associated with a single GTK surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const gio = @import("gio");
const glib = @import("glib");
const Application = @import("class/application.zig").Application;

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
};

const Notification = struct {
    key: Key,
    timeout_source: ?c_uint = null,
};

const TrackResult = struct {
    // Borrows the stored key until the entry is removed or the manager cleared.
    key: Key,
    evicted: ?Notification = null,
};

/// The key borrows stored strings, so cancel the source before freeing them.
const Timeout = struct {
    alloc: Allocator,
    notifications: *DesktopNotifications,
    key: Key,
};

/// Entries are ordered from oldest to newest; replacement refreshes their age.
notifications: std.Deque(Notification) = .empty,
/// Set when the core surface initializes and retained through cleanup.
surface_id: u64 = 0,
/// Bound retained entries because GIO does not report desktop-side dismissals.
limit: usize = default_limit,

pub fn init(surface_id: u64) DesktopNotifications {
    assert(surface_id != 0);
    return .{ .surface_id = surface_id };
}

/// Send or replace a notification for this surface. Content is copied, so the
/// caller may release title and body on return.
pub fn send(
    self: *DesktopNotifications,
    alloc: Allocator,
    focused: bool,
    title: [:0]const u8,
    body: [:0]const u8,
) void {
    assert(self.surface_id != 0);
    const app = Application.default().as(gio.Application);

    const display_title = if (title.len == 0) "Ghostty" else title;
    const notification = gio.Notification.new(display_title);
    defer notification.unref();
    notification.setBody(body);

    const icon = gio.ThemedIcon.new("com.mitchellh.ghostty");
    defer icon.unref();
    notification.setIcon(icon.as(gio.Icon));
    notification.setDefaultActionAndTargetValue(
        "app.present-surface",
        glib.Variant.newUint64(self.surface_id),
    );

    const tracked = self.track(alloc, .{ .title = title, .body = body }) catch |err| {
        log.warn("unable to track desktop notification err={}", .{err});
        return;
    };
    if (tracked.evicted) |evicted| self.clearRemoved(alloc, evicted);

    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, self.surface_id, tracked.key);
    app.sendNotification(id, notification);

    if (focused) self.scheduleTimeout(alloc, tracked.key);
}

/// Withdraw delivered notifications and cancel their timers. GIO's freedesktop
/// backend cannot withdraw a notification until its asynchronous Notify reply
/// arrives. A notification still in flight may therefore outlive this call.
pub fn clear(
    self: *DesktopNotifications,
    alloc: Allocator,
) void {
    while (self.notifications.popFront()) |removed| self.clearRemoved(alloc, removed);
    self.notifications.deinit(alloc);
    self.notifications = .empty;
}

/// Store content and return any evicted entry for withdrawal by the caller.
fn track(
    self: *DesktopNotifications,
    alloc: Allocator,
    key: Key,
) Allocator.Error!TrackResult {
    assert(self.limit > 0);
    if (self.remove(key)) |removed| {
        // Keep the owned strings and move the entry to the newest position.
        cancelTimeout(removed.timeout_source);
        self.notifications.pushBackAssumeCapacity(.{ .key = removed.key });
        return .{ .key = removed.key };
    }

    // Complete allocations before eviction so failure preserves existing entries.
    const stored_key = try key.clone(alloc);
    errdefer stored_key.deinit(alloc);

    var evicted: ?Notification = null;
    if (self.notifications.len >= self.limit) {
        evicted = self.notifications.popFront();
    } else {
        try self.notifications.ensureUnusedCapacity(alloc, 1);
    }

    self.notifications.pushBackAssumeCapacity(.{ .key = stored_key });
    return .{ .key = stored_key, .evicted = evicted };
}

fn find(self: *const DesktopNotifications, key: Key) ?usize {
    var it = self.notifications.iterator();
    var i: usize = 0;
    while (it.next()) |notification| : (i += 1) {
        if (std.mem.eql(u8, notification.key.title, key.title) and
            std.mem.eql(u8, notification.key.body, key.body)) return i;
    }
    return null;
}

/// Remove a matching entry without changing the age of the remaining entries.
fn remove(self: *DesktopNotifications, key: Key) ?Notification {
    var i = self.find(key) orelse return null;
    const removed = self.notifications.at(i);
    while (i + 1 < self.notifications.len) : (i += 1) {
        self.notifications.atPtr(i).* = self.notifications.at(i + 1);
    }
    _ = self.notifications.popBack();
    return removed;
}

/// Cancel the removed entry's timer and withdraw it before freeing its key.
fn clearRemoved(
    self: *DesktopNotifications,
    alloc: Allocator,
    removed: Notification,
) void {
    cancelTimeout(removed.timeout_source);
    self.withdraw(removed.key);
    removed.key.deinit(alloc);
}

fn withdraw(
    self: *DesktopNotifications,
    key: Key,
) void {
    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, self.surface_id, key);
    Application.default().as(gio.Application).withdrawNotification(id);
}

fn scheduleTimeout(
    self: *DesktopNotifications,
    alloc: Allocator,
    key: Key,
) void {
    const notification = self.notifications.atPtr(self.find(key) orelse return);
    assert(notification.timeout_source == null);

    const timeout = alloc.create(Timeout) catch |err| {
        log.warn("unable to allocate desktop notification timer err={}", .{err});
        return;
    };
    timeout.* = .{
        .alloc = alloc,
        .notifications = self,
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
    const removed = timeout.notifications.remove(timeout.key) orelse
        return @intFromBool(glib.SOURCE_REMOVE);
    assert(removed.timeout_source != null);
    // This source is already dispatching. Let SOURCE_REMOVE destroy its callback
    // data after return instead of cancelling it through clearRemoved.
    timeout.notifications.withdraw(removed.key);
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
pub fn deinit(self: *DesktopNotifications, alloc: Allocator) void {
    self.clear(alloc);
}

/// GIO requires the same ID for sending and withdrawing. Including the surface
/// ID keeps identical notifications from different surfaces independent.
/// The fixed buffer fits the prefix, two 16-digit hex values, and a terminator.
fn formatId(
    buf: *[64]u8,
    surface_id: u64,
    key: Key,
) [:0]u8 {
    var hasher = std.hash.Wyhash.init(0);
    std.hash.autoHashStrat(&hasher, key, .Deep);
    return std.fmt.bufPrintZ(
        buf,
        "ghostty-surface-{x}-{x}",
        .{ surface_id, hasher.final() },
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

    // The string boundary is part of the hash, not just the concatenated text.
    const a = formatId(&first_buf, surface_id, .{ .title = "ab", .body = "c" });
    const b = formatId(&repeated_buf, surface_id, .{ .title = "a", .body = "bc" });
    try testing.expect(!std.mem.eql(u8, a, b));
}

test "desktop notifications replace and evict oldest" {
    const testing = std.testing;

    var notifications: DesktopNotifications = .{ .limit = 3 };
    defer {
        while (notifications.notifications.popFront()) |removed| removed.key.deinit(testing.allocator);
        notifications.notifications.deinit(testing.allocator);
    }

    _ = try notifications.track(testing.allocator, .{ .title = "First", .body = "Body" });
    _ = try notifications.track(testing.allocator, .{ .title = "Second", .body = "Body" });
    _ = try notifications.track(testing.allocator, .{ .title = "Third", .body = "Body" });

    const repeated = try notifications.track(testing.allocator, .{ .title = "First", .body = "Body" });
    try testing.expect(repeated.evicted == null);

    const fourth = try notifications.track(testing.allocator, .{ .title = "Fourth", .body = "Body" });
    const evicted = fourth.evicted.?;
    defer evicted.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Second", evicted.key.title);
    try testing.expectEqual(@as(usize, 3), notifications.notifications.len);
}

test "desktop notifications remove and drain independently" {
    const testing = std.testing;

    var first: DesktopNotifications = .init(1);
    defer {
        while (first.notifications.popFront()) |removed| removed.key.deinit(testing.allocator);
        first.notifications.deinit(testing.allocator);
    }
    var second: DesktopNotifications = .init(2);
    defer {
        while (second.notifications.popFront()) |removed| removed.key.deinit(testing.allocator);
        second.notifications.deinit(testing.allocator);
    }

    const first_notification = try first.track(testing.allocator, .{ .title = "Title", .body = "Body" });
    _ = try first.track(testing.allocator, .{ .title = "Other", .body = "Body" });
    _ = try second.track(testing.allocator, .{ .title = "Title", .body = "Body" });

    const removed = first.remove(first_notification.key).?;
    defer removed.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Title", removed.key.title);
    try testing.expectEqual(@as(usize, 1), first.notifications.len);
    try testing.expectEqual(@as(usize, 1), second.notifications.len);

    const drained = first.notifications.popFront().?;
    defer drained.key.deinit(testing.allocator);
    try testing.expectEqualStrings("Other", drained.key.title);
    try testing.expectEqual(@as(usize, 0), first.notifications.len);
    try testing.expect(first.notifications.popFront() == null);
    try testing.expectEqual(@as(usize, 1), second.notifications.len);
}

test "desktop notifications remove from a wrapped deque" {
    const testing = std.testing;
    var notifications: DesktopNotifications = .{ .limit = 3 };
    defer {
        while (notifications.notifications.popFront()) |removed| removed.key.deinit(testing.allocator);
        notifications.notifications.deinit(testing.allocator);
    }
    try notifications.notifications.ensureTotalCapacityPrecise(testing.allocator, 3);
    for ([_][]const u8{ "First", "Second", "Third", "Fourth" }) |title| {
        const tracked = try notifications.track(testing.allocator, .{ .title = title, .body = "Body" });
        if (tracked.evicted) |evicted| evicted.key.deinit(testing.allocator);
    }
    const repeated = try notifications.track(testing.allocator, .{ .title = "Third", .body = "Body" });
    try testing.expect(repeated.evicted == null);
    try testing.expectEqualStrings("Second", notifications.notifications.at(0).key.title);
    try testing.expectEqualStrings("Fourth", notifications.notifications.at(1).key.title);
    try testing.expectEqualStrings("Third", notifications.notifications.at(2).key.title);
    try testing.expect(notifications.remove(.{ .title = "Missing", .body = "Body" }) == null);
}

test "desktop notifications allocation failure preserves entries" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var notifications: DesktopNotifications = .{ .limit = 2 };
            defer {
                while (notifications.notifications.popFront()) |removed| removed.key.deinit(alloc);
                notifications.notifications.deinit(alloc);
            }
            for ([_][]const u8{ "First", "Second", "Third" }, 0..) |title, i| {
                const tracked = notifications.track(alloc, .{ .title = title, .body = "Body" }) catch |err| {
                    try testing.expectEqual(i, notifications.notifications.len);
                    if (i > 0) try testing.expectEqualStrings("First", notifications.notifications.front().?.key.title);
                    return err;
                };
                if (tracked.evicted) |evicted| evicted.key.deinit(alloc);
            }
            try testing.expectEqualStrings("Second", notifications.notifications.front().?.key.title);
        }
    }.run, .{});
}

test "desktop notifications cleanup releases storage and is repeatable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var notifications: DesktopNotifications = .{};
    notifications.clear(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.buffer.len);

    notifications = .init(42);
    const tracked = try notifications.track(alloc, .{ .title = "Title", .body = "Body" });
    const removed = notifications.remove(tracked.key).?;
    removed.key.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.len);
    try testing.expect(notifications.notifications.buffer.len > 0);

    notifications.clear(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.buffer.len);
    notifications.deinit(alloc);
    notifications.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.len);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.buffer.len);
    try testing.expectEqual(@as(u64, 42), notifications.surface_id);
}
