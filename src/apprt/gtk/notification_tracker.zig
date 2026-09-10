//! Tracks desktop notifications associated with a single GTK surface.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const NotificationTracker = @This();

pub const default_limit = 64;

pub const Key = struct {
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

pub const Notification = struct {
    timeout_source: ?c_uint = null,
};

pub const Removed = struct {
    key: Key,
    notification: Notification,

    pub fn deinit(self: Removed, alloc: Allocator) void {
        self.key.deinit(alloc);
    }
};

pub const TrackResult = struct {
    key: Key,
    replaced_timeout: ?c_uint = null,
    evicted: ?Removed = null,
};

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

notifications: Notifications = .empty,
limit: usize,

pub fn init(limit: usize) NotificationTracker {
    assert(limit > 0);
    return .{ .limit = limit };
}

pub fn track(
    self: *NotificationTracker,
    alloc: Allocator,
    title: []const u8,
    body: []const u8,
) Allocator.Error!TrackResult {
    const key: Key = .{ .title = title, .body = body };
    if (self.notifications.fetchOrderedRemove(key)) |removed| {
        self.notifications.putAssumeCapacity(removed.key, .{});
        return .{
            .key = removed.key,
            .replaced_timeout = removed.value.timeout_source,
        };
    }

    const stored_key = try key.clone(alloc);
    errdefer stored_key.deinit(alloc);

    var evicted: ?Removed = null;
    if (self.notifications.count() >= self.limit) {
        evicted = self.pop();
    } else {
        try self.notifications.ensureUnusedCapacity(alloc, 1);
    }

    self.notifications.putAssumeCapacity(stored_key, .{});
    return .{ .key = stored_key, .evicted = evicted };
}

pub fn getPtr(self: *NotificationTracker, key: Key) ?*Notification {
    return self.notifications.getPtr(key);
}

pub fn remove(self: *NotificationTracker, key: Key) ?Removed {
    const removed = self.notifications.fetchOrderedRemove(key) orelse return null;
    return .{ .key = removed.key, .notification = removed.value };
}

pub fn pop(self: *NotificationTracker) ?Removed {
    if (self.notifications.count() == 0) return null;
    return self.remove(self.notifications.keys()[0]);
}

pub fn count(self: *const NotificationTracker) usize {
    return self.notifications.count();
}

pub fn clearAndFree(self: *NotificationTracker, alloc: Allocator) void {
    for (self.notifications.keys()) |key| key.deinit(alloc);
    self.notifications.clearAndFree(alloc);
}

pub fn deinit(self: *NotificationTracker, alloc: Allocator) void {
    self.clearAndFree(alloc);
}

pub fn formatId(
    buf: []u8,
    surface_id: u64,
    key: Key,
) std.fmt.BufPrintError![:0]u8 {
    return std.fmt.bufPrintZ(
        buf,
        "ghostty-surface-{x}-{x}",
        .{ surface_id, key.hash() },
    );
}

test "desktop notification IDs are stable per surface and content" {
    const testing = std.testing;

    const first: Key = .{ .title = "Title", .body = "Body" };
    const repeated: Key = .{ .title = "Title", .body = "Body" };
    const other_title: Key = .{ .title = "Other", .body = "Body" };
    const other_body: Key = .{ .title = "Title", .body = "Other" };

    var first_buf: [64]u8 = undefined;
    const first_id = try formatId(&first_buf, 1, first);
    var repeated_buf: [64]u8 = undefined;
    const repeated_id = try formatId(&repeated_buf, 1, repeated);
    var other_surface_buf: [64]u8 = undefined;
    const other_surface_id = try formatId(&other_surface_buf, 2, first);
    var other_title_buf: [64]u8 = undefined;
    const other_title_id = try formatId(&other_title_buf, 1, other_title);
    var other_body_buf: [64]u8 = undefined;
    const other_body_id = try formatId(&other_body_buf, 1, other_body);

    try testing.expectEqualStrings(first_id, repeated_id);
    try testing.expect(!std.mem.eql(u8, first_id, other_surface_id));
    try testing.expect(!std.mem.eql(u8, first_id, other_title_id));
    try testing.expect(!std.mem.eql(u8, first_id, other_body_id));
}

test "desktop notification tracker replaces and evicts oldest" {
    const testing = std.testing;

    var tracker: NotificationTracker = .init(3);
    defer tracker.deinit(testing.allocator);

    const first = try tracker.track(testing.allocator, "First", "Body");
    tracker.getPtr(first.key).?.timeout_source = 101;
    const second = try tracker.track(testing.allocator, "Second", "Body");
    tracker.getPtr(second.key).?.timeout_source = 202;
    const third = try tracker.track(testing.allocator, "Third", "Body");
    tracker.getPtr(third.key).?.timeout_source = 303;

    const repeated = try tracker.track(testing.allocator, "First", "Body");
    try testing.expectEqual(@as(?c_uint, 101), repeated.replaced_timeout);
    try testing.expectEqual(@as(?c_uint, null), tracker.getPtr(repeated.key).?.timeout_source);
    try testing.expectEqual(@as(?Removed, null), repeated.evicted);

    const fourth = try tracker.track(testing.allocator, "Fourth", "Body");
    try testing.expectEqual(@as(?c_uint, null), fourth.replaced_timeout);
    const evicted = fourth.evicted.?;
    defer evicted.deinit(testing.allocator);
    try testing.expectEqualStrings("Second", evicted.key.title);
    try testing.expectEqual(@as(?c_uint, 202), evicted.notification.timeout_source);
    try testing.expectEqual(@as(usize, 3), tracker.count());
}

test "desktop notification tracker removes and drains independently" {
    const testing = std.testing;

    var first: NotificationTracker = .init(default_limit);
    defer first.deinit(testing.allocator);
    var second: NotificationTracker = .init(default_limit);
    defer second.deinit(testing.allocator);

    const first_notification = try first.track(testing.allocator, "Title", "Body");
    first.getPtr(first_notification.key).?.timeout_source = 101;
    _ = try first.track(testing.allocator, "Other", "Body");
    _ = try second.track(testing.allocator, "Title", "Body");

    const removed = first.remove(first_notification.key).?;
    defer removed.deinit(testing.allocator);
    try testing.expectEqualStrings("Title", removed.key.title);
    try testing.expectEqual(@as(?c_uint, 101), removed.notification.timeout_source);
    try testing.expectEqual(@as(usize, 1), first.count());
    try testing.expectEqual(@as(usize, 1), second.count());

    const drained = first.pop().?;
    defer drained.deinit(testing.allocator);
    try testing.expectEqualStrings("Other", drained.key.title);
    try testing.expectEqual(@as(usize, 0), first.count());
    try testing.expect(first.pop() == null);
    try testing.expectEqual(@as(usize, 1), second.count());
}
