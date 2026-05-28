/// An SSH terminfo entry cache that stores its cache data on
/// disk. The cache only stores metadata (hostname, terminfo value,
/// etc.) and does not store any sensitive data.
const DiskCache = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const internal_os = @import("../../os/main.zig");
const xdg = internal_os.xdg;
const Entry = @import("Entry.zig");

// 512KB - sufficient for approximately 10k entries
const MAX_CACHE_SIZE = 512 * 1024;

/// Path to a file where the cache is stored.
path: []const u8,

/// Returns the default path for the cache for a given program.
///
/// On all platforms, this is `${XDG_STATE_HOME}/ghostty/ssh_cache`.
///
/// The returned value is allocated and must be freed by the caller.
pub fn defaultPath(
    alloc: Allocator,
    program: []const u8,
) ![]const u8 {
    const state_dir: []const u8 = xdg.state(
        alloc,
        .{ .subdir = program },
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.XdgLookupFailed,
    };
    defer alloc.free(state_dir);
    return try std.fs.path.join(alloc, &.{ state_dir, "ssh_cache" });
}

/// Clear all cache data stored in the disk cache.
/// This removes the cache file from disk, effectively clearing all cached
/// SSH terminfo entries.
pub fn clear(self: DiskCache) !void {
    std.fs.cwd().deleteFile(self.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Add or update an entry in the cache, recording `timestamp` (Unix seconds).
/// The cache file is created if it doesn't exist with secure permissions (0600).
pub fn add(
    self: DiskCache,
    alloc: Allocator,
    key: []const u8,
    timestamp: i64,
) !void {
    if (!isValidCacheKey(key)) return error.InvalidCacheKey;

    // Create cache directory if needed
    if (std.fs.path.dirname(self.path)) |dir| {
        std.fs.cwd().makePath(dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Open or create cache file with secure permissions
    const file = std.fs.createFileAbsolute(self.path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            const existing_file = try std.fs.openFileAbsolute(
                self.path,
                .{ .mode = .read_write },
            );
            errdefer existing_file.close();
            try fixupPermissions(existing_file);
            break :blk existing_file;
        },
        else => return err,
    };
    defer file.close();

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(.exclusive) catch return error.CacheLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock();

    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    // Update the timestamp of an existing entry, or insert a new one. For a
    // new entry, dupe both strings up front so a failed allocation never
    // leaves a half-built slot (borrowed key, undefined value) for the
    // `deinitEntries` defer to walk.
    if (entries.getPtr(key)) |existing| {
        existing.timestamp = timestamp;
    } else {
        const key_copy = try alloc.dupe(u8, key);
        errdefer alloc.free(key_copy);
        const terminfo_copy = try alloc.dupe(u8, "xterm-ghostty");
        errdefer alloc.free(terminfo_copy);

        try entries.put(key_copy, .{
            .hostname = key_copy,
            .timestamp = timestamp,
            .terminfo_version = terminfo_copy,
        });
    }

    try self.writeCacheFile(entries);
}

/// Remove an entry from the cache. Returns true if an entry was removed,
/// false if the key wasn't present (or the cache file is missing).
pub fn remove(
    self: DiskCache,
    alloc: Allocator,
    key: []const u8,
) !bool {
    if (!isValidCacheKey(key)) return error.InvalidCacheKey;

    // Open our file
    const file = std.fs.openFileAbsolute(
        self.path,
        .{ .mode = .read_write },
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();
    try fixupPermissions(file);

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(.exclusive) catch return error.CacheLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock();

    // Read existing entries
    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    // Remove the entry if it exists and ensure we free the memory
    const removed = if (entries.fetchRemove(key)) |kv| removed: {
        assert(kv.key.ptr == kv.value.hostname.ptr);
        alloc.free(kv.value.hostname);
        alloc.free(kv.value.terminfo_version);
        break :removed true;
    } else false;

    try self.writeCacheFile(entries);
    return removed;
}

/// Remove all entries older than `max_age_s` seconds and return how many
/// were pruned. Returns zero (and nothing written) if the cache file is
/// missing.
pub fn prune(
    self: DiskCache,
    alloc: Allocator,
    max_age_s: u64,
) !usize {
    const file = std.fs.openFileAbsolute(
        self.path,
        .{ .mode = .read_write },
    ) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => return err,
    };
    defer file.close();
    try fixupPermissions(file);

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(.exclusive) catch return error.CacheLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock();

    // Read existing entries
    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    // Drop expired entries from the map, then persist what remains.
    const now = std.time.timestamp();
    var expired: std.ArrayList([]const u8) = .empty;
    defer expired.deinit(alloc);
    var iter = entries.iterator();
    while (iter.next()) |kv| {
        const age_s = now -| kv.value_ptr.timestamp;
        if (age_s > max_age_s) try expired.append(alloc, kv.key_ptr.*);
    }
    for (expired.items) |key| {
        const kv = entries.fetchRemove(key).?;
        assert(kv.key.ptr == kv.value.hostname.ptr);
        alloc.free(kv.value.hostname);
        alloc.free(kv.value.terminfo_version);
    }

    try self.writeCacheFile(entries);
    return expired.items.len;
}

/// Check if a key exists in the cache.
/// Returns false if the cache file doesn't exist.
pub fn contains(
    self: DiskCache,
    alloc: Allocator,
    key: []const u8,
) !bool {
    if (!isValidCacheKey(key)) return error.InvalidCacheKey;

    // Open our file
    const file = std.fs.openFileAbsolute(
        self.path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    // Read existing entries
    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    return entries.contains(key);
}

fn fixupPermissions(file: std.fs.File) !void {
    // Windows does not support chmod
    if (comptime builtin.os.tag == .windows) return;

    // Ensure file has correct permissions (readable/writable by
    // owner only)
    const stat = try file.stat();
    if (stat.mode & 0o777 != 0o600) {
        try file.chmod(0o600);
    }
}

fn writeCacheFile(
    self: DiskCache,
    entries: std.StringHashMap(Entry),
) !void {
    const cache_dir = std.fs.path.dirname(self.path) orelse return error.InvalidCachePath;
    const cache_basename = std.fs.path.basename(self.path);

    var dir = try std.fs.cwd().openDir(cache_dir, .{});
    defer dir.close();

    var buf: [1024]u8 = undefined;
    var atomic_file = try dir.atomicFile(cache_basename, .{
        .mode = 0o600,
        .write_buffer = &buf,
    });
    defer atomic_file.deinit();

    var iter = entries.iterator();
    while (iter.next()) |kv| {
        try kv.value_ptr.format(&atomic_file.file_writer.interface);
    }

    try atomic_file.finish();
}

/// List all entries in the cache.
/// The returned HashMap must be freed using `deinitEntries`.
/// Returns an empty map if the cache file doesn't exist.
pub fn list(
    self: DiskCache,
    alloc: Allocator,
) !std.StringHashMap(Entry) {
    // Open our file
    const file = std.fs.openFileAbsolute(
        self.path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return .init(alloc),
        else => return err,
    };
    defer file.close();
    return readEntries(alloc, file);
}

/// Free memory allocated by the `list` function.
/// This must be called to properly deallocate all entry data.
pub fn deinitEntries(
    alloc: Allocator,
    entries: *std.StringHashMap(Entry),
) void {
    // All our entries we dupe the memory owned by the hostname and the
    // terminfo, and we always match the hostname key and value.
    var it = entries.iterator();
    while (it.next()) |entry| {
        assert(entry.key_ptr.*.ptr == entry.value_ptr.hostname.ptr);
        alloc.free(entry.value_ptr.hostname);
        alloc.free(entry.value_ptr.terminfo_version);
    }
    entries.deinit();
}

fn readEntries(
    alloc: Allocator,
    file: std.fs.File,
) !std.StringHashMap(Entry) {
    var reader = file.reader(&.{});
    const content = try reader.interface.allocRemaining(
        alloc,
        .limited(MAX_CACHE_SIZE),
    );
    defer alloc.free(content);

    var entries = std.StringHashMap(Entry).init(alloc);
    errdefer deinitEntries(alloc, &entries);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const entry = Entry.parse(trimmed) orelse continue;

        // Dupe both strings up front, before inserting, so the map never
        // holds a half-built entry (a borrowed key or a freed/undefined
        // value) for `deinitEntries` to walk if an allocation fails.
        var hostname: ?[]u8 = try alloc.dupe(u8, entry.hostname);
        errdefer if (hostname) |h| alloc.free(h);
        var terminfo: ?[]u8 = try alloc.dupe(u8, entry.terminfo_version);
        errdefer if (terminfo) |t| alloc.free(t);

        const gop = try entries.getOrPut(hostname.?);
        if (!gop.found_existing) {
            // New entry: transfer both copies to the map.
            gop.value_ptr.* = .{
                .hostname = hostname.?,
                .timestamp = entry.timestamp,
                .terminfo_version = terminfo.?,
            };
            hostname = null;
            terminfo = null;
        } else {
            // Duplicate key: the map keeps its existing key, so free ours.
            alloc.free(hostname.?);
            hostname = null;

            // Handle duplicate entries - keep newer timestamp
            if (entry.timestamp > gop.value_ptr.timestamp) {
                gop.value_ptr.timestamp = entry.timestamp;
                if (!std.mem.eql(
                    u8,
                    gop.value_ptr.terminfo_version,
                    terminfo.?,
                )) {
                    alloc.free(gop.value_ptr.terminfo_version);
                    gop.value_ptr.terminfo_version = terminfo.?;
                    terminfo = null;
                }
            }
            if (terminfo) |t| alloc.free(t);
            terminfo = null;
        }
    }

    return entries;
}

// Supports both standalone hostnames and user@hostname format
pub fn isValidCacheKey(key: []const u8) bool {
    if (key.len == 0) return false;

    // Check for user@hostname format
    if (std.mem.indexOfScalar(u8, key, '@')) |at_pos| {
        const user = key[0..at_pos];
        const hostname = key[at_pos + 1 ..];
        return isValidUser(user) and isValidHost(hostname);
    }

    return isValidHost(key);
}

// Checks if a host is a valid hostname or IP address
fn isValidHost(host: []const u8) bool {
    // First check for valid hostnames because this is assumed to be the more
    // likely ssh host format.
    if (internal_os.hostname.isValid(host)) {
        return true;
    }

    // We also accept valid IP addresses. In practice, IPv4 addresses are also
    // considered valid hostnames due to their overlapping syntax, so we can
    // simplify this check to be IPv6-specific.
    if (std.net.Address.parseIp6(host, 0)) |_| {
        return true;
    } else |_| {
        return false;
    }
}

fn isValidUser(user: []const u8) bool {
    if (user.len == 0 or user.len > 64) return false;
    for (user) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-', '.' => {},
            else => return false,
        }
    }
    return true;
}

test "disk cache default path" {
    const testing = std.testing;
    const alloc = std.testing.allocator;

    const path = try DiskCache.defaultPath(alloc, "ghostty");
    defer alloc.free(path);
    try testing.expect(path.len > 0);
}

test "disk cache clear" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create our path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    {
        var file = try tmp.dir.createFile("cache", .{});
        defer file.close();
        var file_writer = file.writer(&buf);
        try file_writer.interface.writeAll("HELLO!");
    }
    const path = try tmp.dir.realpathAlloc(alloc, "cache");
    defer alloc.free(path);

    // Setup our cache
    const cache: DiskCache = .{ .path = path };
    try cache.clear();

    // Verify the file is gone
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile("cache", .{}),
    );
}

test "disk cache operations" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create our path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    {
        var file = try tmp.dir.createFile("cache", .{});
        defer file.close();
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;
        try writer.writeAll("HELLO!");
        try writer.flush();
    }
    const path = try tmp.dir.realpathAlloc(alloc, "cache");
    defer alloc.free(path);

    // Setup our cache. Adding the same key twice exercises both the new
    // and existing-entry paths.
    const cache: DiskCache = .{ .path = path };
    try cache.add(alloc, "example.com", std.time.timestamp());
    try cache.add(alloc, "example.com", std.time.timestamp());
    try testing.expect(try cache.contains(alloc, "example.com"));

    // List
    var entries = try cache.list(alloc);
    deinitEntries(alloc, &entries);

    // Remove reports that it removed the entry, and a second remove of the
    // same key reports nothing to remove.
    try testing.expect(try cache.remove(alloc, "example.com"));
    try testing.expect(!try cache.remove(alloc, "example.com"));
    try testing.expect(!(try cache.contains(alloc, "example.com")));
    try cache.add(alloc, "example.com", std.time.timestamp());
}

test "disk cache cleans up temp files" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const cache_path = try std.fs.path.join(alloc, &.{ tmp_path, "cache" });
    defer alloc.free(cache_path);

    const cache: DiskCache = .{ .path = cache_path };
    try cache.add(alloc, "example.com", std.time.timestamp());
    try cache.add(alloc, "example.org", std.time.timestamp());

    // Verify only the cache file exists and no temp files left behind
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (try iter.next()) |entry| {
        count += 1;
        try testing.expectEqualStrings("cache", entry.name);
    }
    try testing.expectEqual(1, count);
}

test "disk cache prune" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const cache_path = try std.fs.path.join(alloc, &.{ tmp_path, "cache" });
    defer alloc.free(cache_path);

    const cache: DiskCache = .{ .path = cache_path };

    // Back-date one entry an hour old and one 100 days old.
    const day = std.time.s_per_day;
    const hour = std.time.s_per_hour;
    const now = std.time.timestamp();
    try cache.add(alloc, "recent.com", now - hour);
    try cache.add(alloc, "old.com", now - 100 * day);

    // Prune entries older than 90 days: only old.com goes.
    try testing.expectEqual(@as(usize, 1), try cache.prune(alloc, 90 * day));
    try testing.expect(try cache.contains(alloc, "recent.com"));
    try testing.expect(!try cache.contains(alloc, "old.com"));

    // Pruning again removes nothing.
    try testing.expectEqual(@as(usize, 0), try cache.prune(alloc, 90 * day));

    // Sub-day granularity: a 30-minute max age prunes the hour-old entry.
    try testing.expectEqual(@as(usize, 1), try cache.prune(alloc, 30 * std.time.s_per_min));
    try testing.expect(!try cache.contains(alloc, "recent.com"));
}

test "disk cache prune missing file" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(tmp_path);
    const cache_path = try std.fs.path.join(alloc, &.{ tmp_path, "cache" });
    defer alloc.free(cache_path);

    const cache: DiskCache = .{ .path = cache_path };
    try testing.expectEqual(@as(usize, 0), try cache.prune(alloc, 30));
}

test "disk cache reads duplicate keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exercise readEntries' found_existing branch: replace the existing
    // key with the updated entry and ensure (via testing.allocator) that
    // we don't double-free or leak.
    {
        var file = try tmp.dir.createFile("cache", .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        var file_writer = file.writer(&buf);
        try file_writer.interface.writeAll(
            "example.com|100|xterm-ghostty\nexample.com|200|xterm-newer\n",
        );
        try file_writer.interface.flush();
    }
    const path = try tmp.dir.realpathAlloc(alloc, "cache");
    defer alloc.free(path);

    const cache: DiskCache = .{ .path = path };
    var entries = try cache.list(alloc);
    defer deinitEntries(alloc, &entries);

    try testing.expectEqual(@as(u32, 1), entries.count());
    const entry = entries.get("example.com").?;
    try testing.expectEqual(@as(i64, 200), entry.timestamp);
    try testing.expectEqualStrings("xterm-newer", entry.terminfo_version);
}

test "disk cache reads survive allocation failure" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exercise a populated cache containing a duplicate key to ensure
    // that we hit all of the possible allocation behaviors below.
    {
        var file = try tmp.dir.createFile("cache", .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        var file_writer = file.writer(&buf);
        try file_writer.interface.writeAll(
            "a.com|100|xterm-ghostty\n" ++
                "b.com|100|xterm-ghostty\n" ++
                "c.com|100|xterm-ghostty\n" ++
                "a.com|200|xterm-newer\n",
        );
        try file_writer.interface.flush();
    }
    const path = try tmp.dir.realpathAlloc(testing.allocator, "cache");
    defer testing.allocator.free(path);

    const cache: DiskCache = .{ .path = path };

    // Fail the Nth allocation for every N until the read completes. The
    // FailingAllocator is backed by testing.allocator so we also ensure
    // that we don't double-free or leak; this can only completely succeed
    // or fail with OutOfMemory.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();

        if (cache.list(alloc)) |entries_const| {
            var entries = entries_const;
            deinitEntries(alloc, &entries);
            // Reached a run with no induced failure: every path covered.
            if (!failing.has_induced_failure) break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test "disk cache add survives allocation failure" {
    const testing = std.testing;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_path);
    const path = try std.fs.path.join(testing.allocator, &.{ tmp_path, "cache" });
    defer testing.allocator.free(path);

    const cache: DiskCache = .{ .path = path };

    // Fail the Nth allocation for every N until add completes. A failed add
    // must not leak or leave a half-built map entry. The FailingAllocator
    // is backed by testing.allocator to catch either. Each iteration starts
    // from a clean cache file.
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        std.fs.cwd().deleteFile(path) catch {};
        var failing = std.testing.FailingAllocator.init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const alloc = failing.allocator();

        if (cache.add(alloc, "user@example.com", 100)) |_| {
            if (!failing.has_induced_failure) break;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
        }
    }
}

test isValidHost {
    const testing = std.testing;

    // Valid hostnames
    try testing.expect(isValidHost("localhost"));
    try testing.expect(isValidHost("example.com"));
    try testing.expect(isValidHost("sub.example.com"));

    // IPv4 addresses
    try testing.expect(isValidHost("127.0.0.1"));
    try testing.expect(isValidHost("192.168.1.1"));

    // IPv6 addresses
    try testing.expect(isValidHost("::1"));
    try testing.expect(isValidHost("2001:db8::1"));
    try testing.expect(isValidHost("2001:db8:0:1:1:1:1:1"));
    try testing.expect(!isValidHost("fe80::1%eth0")); // scopes not supported

    // Invalid hosts
    try testing.expect(!isValidHost(""));
    try testing.expect(!isValidHost("host\nname"));
    try testing.expect(!isValidHost(".example.com"));
    try testing.expect(!isValidHost("host..domain"));
    try testing.expect(!isValidHost("-hostname"));
    try testing.expect(!isValidHost("hostname-"));
    try testing.expect(!isValidHost("host name"));
    try testing.expect(!isValidHost("host_name"));
    try testing.expect(!isValidHost("host@domain"));
    try testing.expect(!isValidHost("host:port"));
}

test isValidUser {
    const testing = std.testing;

    // Valid
    try testing.expect(isValidUser("user"));
    try testing.expect(isValidUser("user-user"));
    try testing.expect(isValidUser("user_name"));
    try testing.expect(isValidUser("user.name"));
    try testing.expect(isValidUser("user123"));

    // Invalid
    try testing.expect(!isValidUser(""));
    try testing.expect(!isValidUser("user name"));
    try testing.expect(!isValidUser("user@example"));
    try testing.expect(!isValidUser("user:group"));
    try testing.expect(!isValidUser("user\nname"));
    try testing.expect(!isValidUser("a" ** 65)); // too long
}

test isValidCacheKey {
    const testing = std.testing;

    // Valid
    try testing.expect(isValidCacheKey("example.com"));
    try testing.expect(isValidCacheKey("sub.example.com"));
    try testing.expect(isValidCacheKey("192.168.1.1"));
    try testing.expect(isValidCacheKey("::1"));
    try testing.expect(isValidCacheKey("user@example.com"));
    try testing.expect(isValidCacheKey("user@192.168.1.1"));
    try testing.expect(isValidCacheKey("user@::1"));

    // Invalid
    try testing.expect(!isValidCacheKey(""));
    try testing.expect(!isValidCacheKey(".example.com"));
    try testing.expect(!isValidCacheKey("@example.com"));
    try testing.expect(!isValidCacheKey("user@"));
    try testing.expect(!isValidCacheKey("user@@example"));
    try testing.expect(!isValidCacheKey("user@.example.com"));
}
