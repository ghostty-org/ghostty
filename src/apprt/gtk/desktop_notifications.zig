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

const Notification = struct {
    hash: u64,
    timeout_source: ?c_uint = null,
};

const Timeout = struct {
    alloc: Allocator,
    notifications: *DesktopNotifications,
    hash: u64,
};

/// Tracked notification hashes. Replacements are appended as new entries.
notifications: std.ArrayList(Notification) = .empty,
/// Set when the core surface initializes and retained through cleanup.
surface_id: u64 = 0,
/// Bound retained entries because GIO does not report desktop-side dismissals.
limit: usize = default_limit,

pub fn init(surface_id: u64) DesktopNotifications {
    assert(surface_id != 0);
    return .{ .surface_id = surface_id };
}

/// Send or replace a notification for this surface. The caller may release
/// title and body on return.
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

    const hash = notificationHash(title, body);
    const tracked = blk: {
        const evicted = self.track(alloc, hash) catch |err| {
            log.warn("unable to track desktop notification err={}", .{err});
            break :blk false;
        };
        if (evicted) |removed| self.clearRemoved(removed);
        break :blk true;
    };

    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, self.surface_id, hash);
    app.sendNotification(id, notification);

    if (focused and tracked) self.scheduleTimeout(alloc, hash);
}

/// Withdraw delivered notifications and cancel their timers. GIO's freedesktop
/// backend cannot withdraw a notification until its asynchronous Notify reply
/// arrives. A notification still in flight may therefore outlive this call.
pub fn clear(
    self: *DesktopNotifications,
    alloc: Allocator,
) void {
    for (self.notifications.items) |removed| self.clearRemoved(removed);
    self.notifications.deinit(alloc);
    self.notifications = .empty;
}

/// Store a hash and return any evicted entry for withdrawal by the caller.
fn track(
    self: *DesktopNotifications,
    alloc: Allocator,
    hash: u64,
) Allocator.Error!?Notification {
    assert(self.limit > 0);
    if (self.remove(hash)) |removed| {
        // Move the entry to the newest position and reset its timer.
        cancelTimeout(removed.timeout_source);
        self.notifications.appendAssumeCapacity(.{ .hash = hash });
        return null;
    }

    var evicted: ?Notification = null;
    if (self.notifications.items.len >= self.limit) {
        evicted = self.notifications.orderedRemove(0);
    } else {
        try self.notifications.ensureUnusedCapacity(alloc, 1);
    }

    self.notifications.appendAssumeCapacity(.{ .hash = hash });
    return evicted;
}

fn find(self: *const DesktopNotifications, hash: u64) ?usize {
    for (self.notifications.items, 0..) |notification, i| {
        if (notification.hash == hash) return i;
    }
    return null;
}

/// Remove a matching entry without preserving the order of the remaining items.
fn remove(self: *DesktopNotifications, hash: u64) ?Notification {
    const i = self.find(hash) orelse return null;
    return self.notifications.swapRemove(i);
}

/// Cancel the removed entry's timer and withdraw it.
fn clearRemoved(
    self: *DesktopNotifications,
    removed: Notification,
) void {
    cancelTimeout(removed.timeout_source);
    self.withdraw(removed.hash);
}

fn withdraw(
    self: *DesktopNotifications,
    hash: u64,
) void {
    var id_buf: [64]u8 = undefined;
    const id = formatId(&id_buf, self.surface_id, hash);
    Application.default().as(gio.Application).withdrawNotification(id);
}

fn scheduleTimeout(
    self: *DesktopNotifications,
    alloc: Allocator,
    hash: u64,
) void {
    const notification = &self.notifications.items[self.find(hash) orelse return];
    assert(notification.timeout_source == null);

    const timeout = alloc.create(Timeout) catch |err| {
        log.warn("unable to allocate desktop notification timer err={}", .{err});
        return;
    };
    timeout.* = .{
        .alloc = alloc,
        .notifications = self,
        .hash = hash,
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
    const removed = timeout.notifications.remove(timeout.hash) orelse
        return @intFromBool(glib.SOURCE_REMOVE);
    assert(removed.timeout_source != null);
    // This source is already dispatching. Let SOURCE_REMOVE destroy its callback
    // data after return instead of cancelling it through clearRemoved.
    timeout.notifications.withdraw(removed.hash);
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

fn notificationHash(title: []const u8, body: []const u8) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(title);
    hasher.update(body);
    return hasher.final();
}

/// GIO requires the same ID for sending and withdrawing. Including the surface
/// ID keeps identical notifications from different surfaces independent.
/// The fixed buffer fits the prefix, two 16-digit hex values, and a terminator.
fn formatId(
    buf: *[64]u8,
    surface_id: u64,
    hash: u64,
) [:0]u8 {
    return std.mem.printSentinel(
        buf,
        "ghostty-surface-{x}-{x}",
        .{ surface_id, hash },
        0,
    ) catch unreachable;
}

test "desktop notification IDs are stable per surface and content" {
    const testing = std.testing;

    const first = notificationHash("Title", "Body");
    const repeated = notificationHash("Title", "Body");
    const other_title = notificationHash("Other", "Body");
    const other_body = notificationHash("Title", "Other");

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

    // Title and body are hashed as concatenated bytes.
    const a = formatId(&first_buf, surface_id, notificationHash("ab", "c"));
    const b = formatId(&repeated_buf, surface_id, notificationHash("a", "bc"));
    try testing.expectEqualStrings(a, b);
}

test "desktop notifications replace and evict first entry" {
    const testing = std.testing;

    var notifications: DesktopNotifications = .{ .limit = 3 };
    defer notifications.notifications.deinit(testing.allocator);

    _ = try notifications.track(testing.allocator, 1);
    _ = try notifications.track(testing.allocator, 2);
    _ = try notifications.track(testing.allocator, 3);

    try testing.expect(try notifications.track(testing.allocator, 1) == null);

    const evicted = (try notifications.track(testing.allocator, 4)).?;
    try testing.expectEqual(@as(u64, 3), evicted.hash);
    try testing.expectEqual(@as(usize, 3), notifications.notifications.items.len);
}

test "desktop notifications remove and drain independently" {
    const testing = std.testing;

    var first: DesktopNotifications = .init(1);
    defer first.notifications.deinit(testing.allocator);
    var second: DesktopNotifications = .init(2);
    defer second.notifications.deinit(testing.allocator);

    _ = try first.track(testing.allocator, 1);
    _ = try first.track(testing.allocator, 2);
    _ = try second.track(testing.allocator, 1);

    const removed = first.remove(1).?;
    try testing.expectEqual(@as(u64, 1), removed.hash);
    try testing.expectEqual(@as(usize, 1), first.notifications.items.len);
    try testing.expectEqual(@as(usize, 1), second.notifications.items.len);

    const drained = first.remove(2).?;
    try testing.expectEqual(@as(u64, 2), drained.hash);
    try testing.expectEqual(@as(usize, 0), first.notifications.items.len);
    try testing.expect(first.remove(2) == null);
    try testing.expectEqual(@as(usize, 1), second.notifications.items.len);
}

test "desktop notification removal swaps in the last entry" {
    const testing = std.testing;
    var notifications: DesktopNotifications = .{ .limit = 3 };
    defer notifications.notifications.deinit(testing.allocator);
    try notifications.notifications.ensureTotalCapacityPrecise(testing.allocator, 3);
    for ([_]u64{ 1, 2, 3, 4 }) |hash| {
        _ = try notifications.track(testing.allocator, hash);
    }
    try testing.expect(try notifications.track(testing.allocator, 3) == null);
    try testing.expectEqual(@as(u64, 2), notifications.notifications.items[0].hash);
    try testing.expectEqual(@as(u64, 4), notifications.notifications.items[1].hash);
    try testing.expectEqual(@as(u64, 3), notifications.notifications.items[2].hash);
    try testing.expect(notifications.remove(5) == null);
    _ = notifications.remove(4).?;
    try testing.expectEqual(@as(u64, 2), notifications.notifications.items[0].hash);
    try testing.expectEqual(@as(u64, 3), notifications.notifications.items[1].hash);
}

test "desktop notifications allocation failure preserves entries" {
    const testing = std.testing;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn run(alloc: Allocator) !void {
            var notifications: DesktopNotifications = .{ .limit = 2 };
            defer notifications.notifications.deinit(alloc);
            // Force growth with an existing entry to exercise failure preservation.
            try notifications.notifications.ensureTotalCapacityPrecise(alloc, 1);
            for ([_]u64{ 1, 2, 3 }, 0..) |hash, i| {
                _ = notifications.track(alloc, hash) catch |err| {
                    try testing.expectEqual(i, notifications.notifications.items.len);
                    try testing.expectEqual(@as(u64, 1), notifications.notifications.items[0].hash);
                    return err;
                };
            }
            try testing.expectEqual(@as(u64, 2), notifications.notifications.items[0].hash);
        }
    }.run, .{});
}

test "desktop notifications cleanup releases storage and is repeatable" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var notifications: DesktopNotifications = .{};
    notifications.clear(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.capacity);

    notifications = .init(42);
    _ = try notifications.track(alloc, 1);
    _ = notifications.remove(1).?;
    try testing.expectEqual(@as(usize, 0), notifications.notifications.items.len);
    try testing.expect(notifications.notifications.capacity > 0);

    notifications.clear(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.capacity);
    notifications.deinit(alloc);
    notifications.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.items.len);
    try testing.expectEqual(@as(usize, 0), notifications.notifications.capacity);
    try testing.expectEqual(@as(u64, 42), notifications.surface_id);
}
