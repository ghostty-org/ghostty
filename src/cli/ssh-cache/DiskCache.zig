/// An SSH terminfo entry cache that stores its cache data on
/// disk. The cache only stores metadata (hostname, terminfo value,
/// etc.) and does not store any sensitive data.
const DiskCache = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const xdg = @import("../../os/main.zig").xdg;
const TempDir = @import("../../os/main.zig").TempDir;
const Entry = @import("Entry.zig");

// 512KB - sufficient for approximately 10k entries
const MAX_CACHE_SIZE = 512 * 1024;

/// Path to a file where the cache is stored.
path: []const u8,

pub const DefaultPathError = Allocator.Error || error{
    /// The general error that is returned for any filesystem error
    /// that may have resulted in the XDG lookup failing.
    XdgLookupFailed,
};

pub const Error = error{ CacheIsLocked, HostnameIsInvalid };

/// Returns the default path for the cache for a given program.
///
/// On all platforms, this is `${XDG_STATE_HOME}/ghostty/ssh_cache`.
///
/// The returned value is allocated and must be freed by the caller.
pub fn defaultPath(
    alloc: Allocator,
    program: []const u8,
) DefaultPathError![]const u8 {
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

pub const AddResult = enum { added, updated };

pub const AddError = std.fs.Dir.MakeError || std.fs.File.OpenError || std.fs.File.LockError || std.fs.File.ReadError || std.fs.File.WriteError || std.posix.RealPathError || std.posix.RenameError || Allocator.Error || error{ HostnameIsInvalid, CacheIsLocked };

/// Add or update a hostname entry in the cache.
/// Returns AddResult.added for new entries or AddResult.updated for existing ones.
/// The cache file is created if it doesn't exist with secure permissions (0600).
pub fn add(
    self: DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) AddError!AddResult {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

    // Create cache directory if needed
    if (std.fs.path.dirname(self.path)) |dir| {
        std.fs.makeDirAbsolute(dir) catch |err| switch (err) {
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
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(.exclusive) catch return error.CacheIsLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock();

    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    // Add or update entry
    const gop = try entries.getOrPut(hostname);
    const result: AddResult = if (!gop.found_existing) add: {
        const hostname_copy = try alloc.dupe(u8, hostname);
        errdefer alloc.free(hostname_copy);
        const terminfo_copy = try alloc.dupe(u8, "xterm-ghostty");
        errdefer alloc.free(terminfo_copy);

        gop.key_ptr.* = hostname_copy;
        gop.value_ptr.* = .{
            .hostname = gop.key_ptr.*,
            .timestamp = std.time.timestamp(),
            .terminfo_version = terminfo_copy,
        };
        break :add .added;
    } else update: {
        // Update timestamp for existing entry
        gop.value_ptr.timestamp = std.time.timestamp();
        break :update .updated;
    };

    try self.writeCacheFile(alloc, entries, null);
    return result;
}

pub const RemoveError = std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.ReadError || std.fs.File.WriteError || std.posix.RealPathError || std.posix.RenameError || Allocator.Error || error{ HostnameIsInvalid, CacheIsLocked };

/// Remove a hostname entry from the cache.
/// No error is returned if the hostname doesn't exist or the cache file is missing.
pub fn remove(
    self: DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) RemoveError!void {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

    // Open our file
    const file = std.fs.openFileAbsolute(
        self.path,
        .{ .mode = .read_write },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();
    try fixupPermissions(file);

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(.exclusive) catch return error.CacheIsLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock();

    // Read existing entries
    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    // Remove the entry if it exists and ensure we free the memory
    if (entries.fetchRemove(hostname)) |kv| {
        assert(kv.key.ptr == kv.value.hostname.ptr);
        alloc.free(kv.value.hostname);
        alloc.free(kv.value.terminfo_version);
    }

    try self.writeCacheFile(alloc, entries, null);
}

/// Check if a hostname exists in the cache.
/// Returns false if the cache file doesn't exist.
pub fn contains(
    self: DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) !bool {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

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

    // Read existing entries
    var entries = try readEntries(alloc, file);
    defer deinitEntries(alloc, &entries);

    return entries.contains(hostname);
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

pub const WriteCacheFileError = std.fs.Dir.OpenError || std.fs.File.OpenError || std.fs.File.WriteError || std.fs.Dir.RealPathAllocError || std.posix.RealPathError || std.posix.RenameError || error{FileTooBig};

fn writeCacheFile(
    self: DiskCache,
    alloc: Allocator,
    entries: std.StringHashMap(Entry),
    expire_days: ?u32,
) WriteCacheFileError!void {
    var td: TempDir = try .init();
    defer td.deinit();

    const tmp_file = try td.dir.createFile("ssh-cache", .{ .mode = 0o600 });
    defer tmp_file.close();
    const tmp_path = try td.dir.realpathAlloc(alloc, "ssh-cache");
    defer alloc.free(tmp_path);

    const writer = tmp_file.writer();
    var iter = entries.iterator();
    while (iter.next()) |kv| {
        // Only write non-expired entries
        if (kv.value_ptr.isExpired(expire_days)) continue;
        try kv.value_ptr.format(writer);
    }

    // Atomic replace
    try std.fs.renameAbsolute(tmp_path, self.path);
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
) (std.fs.File.ReadError || Allocator.Error || error{FileTooBig})!std.StringHashMap(Entry) {
    const content = try file.readToEndAlloc(alloc, MAX_CACHE_SIZE);
    defer alloc.free(content);

    var entries = std.StringHashMap(Entry).init(alloc);
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const entry = Entry.parse(trimmed) orelse continue;

        // Always allocate hostname first to avoid key pointer confusion
        const hostname = try alloc.dupe(u8, entry.hostname);
        errdefer alloc.free(hostname);

        const gop = try entries.getOrPut(hostname);
        if (!gop.found_existing) {
            const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
            gop.value_ptr.* = .{
                .hostname = hostname,
                .timestamp = entry.timestamp,
                .terminfo_version = terminfo_copy,
            };
        } else {
            // Don't need the copy since entry already exists
            alloc.free(hostname);

            // Handle duplicate entries - keep newer timestamp
            if (entry.timestamp > gop.value_ptr.timestamp) {
                gop.value_ptr.timestamp = entry.timestamp;
                if (!std.mem.eql(
                    u8,
                    gop.value_ptr.terminfo_version,
                    entry.terminfo_version,
                )) {
                    alloc.free(gop.value_ptr.terminfo_version);
                    const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
                    gop.value_ptr.terminfo_version = terminfo_copy;
                }
            }
        }
    }

    return entries;
}

// Supports both standalone hostnames and user@hostname format
fn isValidCacheKey(key: []const u8) bool {
    // 253 + 1 + 64 for user@hostname
    if (key.len == 0 or key.len > 320) return false;

    // Check for user@hostname format
    if (std.mem.indexOf(u8, key, "@")) |at_pos| {
        const user = key[0..at_pos];
        const hostname = key[at_pos + 1 ..];
        return isValidUser(user) and isValidHostname(hostname);
    }

    return isValidHostname(key);
}

// Basic hostname validation - accepts domains and IPs
// (including IPv6 in brackets)
fn isValidHostname(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;

    // Handle IPv6 addresses in brackets
    if (host.len >= 4 and host[0] == '[' and host[host.len - 1] == ']') {
        const ipv6_part = host[1 .. host.len - 1];
        if (ipv6_part.len == 0) return false;
        var has_colon = false;
        for (ipv6_part) |c| {
            switch (c) {
                'a'...'f', 'A'...'F', '0'...'9' => {},
                ':' => has_colon = true,
                else => return false,
            }
        }
        return has_colon;
    }

    // Standard hostname/domain validation
    for (host) |c| {
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '.', '-' => {},
            else => return false,
        }
    }

    // No leading/trailing dots or hyphens, no consecutive dots
    if (host[0] == '.' or host[0] == '-' or
        host[host.len - 1] == '.' or host[host.len - 1] == '-')
    {
        return false;
    }

    return std.mem.indexOf(u8, host, "..") == null;
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
    var td: TempDir = try .init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("cache", .{});
        defer file.close();
        try file.writer().writeAll("HELLO!");
    }
    const path = try td.dir.realpathAlloc(alloc, "cache");
    defer alloc.free(path);

    // Setup our cache
    const cache: DiskCache = .{ .path = path };
    try cache.clear();

    // Verify the file is gone
    try testing.expectError(
        error.FileNotFound,
        td.dir.openFile("cache", .{}),
    );
}

test "disk cache operations" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Create our path
    var td: TempDir = try .init();
    defer td.deinit();
    {
        var file = try td.dir.createFile("cache", .{});
        defer file.close();
        try file.writer().writeAll("HELLO!");
    }
    const path = try td.dir.realpathAlloc(alloc, "cache");
    defer alloc.free(path);

    // Setup our cache
    const cache: DiskCache = .{ .path = path };
    try testing.expectEqual(
        AddResult.added,
        try cache.add(alloc, "example.com"),
    );
    try testing.expectEqual(
        AddResult.updated,
        try cache.add(alloc, "example.com"),
    );
    try testing.expect(
        try cache.contains(alloc, "example.com"),
    );

    // List
    var entries = try cache.list(alloc);
    deinitEntries(alloc, &entries);

    // Remove
    try cache.remove(alloc, "example.com");
    try testing.expect(
        !(try cache.contains(alloc, "example.com")),
    );
    try testing.expectEqual(
        AddResult.added,
        try cache.add(alloc, "example.com"),
    );
}

// Tests
test "hostname validation - valid cases" {
    const testing = std.testing;
    try testing.expect(isValidHostname("example.com"));
    try testing.expect(isValidHostname("sub.example.com"));
    try testing.expect(isValidHostname("host-name.domain.org"));
    try testing.expect(isValidHostname("192.168.1.1"));
    try testing.expect(isValidHostname("a"));
    try testing.expect(isValidHostname("1"));
}

test "hostname validation - IPv6 addresses" {
    const testing = std.testing;
    try testing.expect(isValidHostname("[::1]"));
    try testing.expect(isValidHostname("[2001:db8::1]"));
    try testing.expect(!isValidHostname("[fe80::1%eth0]")); // Interface notation not supported
    try testing.expect(!isValidHostname("[]")); // Empty IPv6
    try testing.expect(!isValidHostname("[invalid]")); // No colons
}

test "hostname validation - invalid cases" {
    const testing = std.testing;
    try testing.expect(!isValidHostname(""));
    try testing.expect(!isValidHostname("host\nname"));
    try testing.expect(!isValidHostname(".example.com"));
    try testing.expect(!isValidHostname("example.com."));
    try testing.expect(!isValidHostname("host..domain"));
    try testing.expect(!isValidHostname("-hostname"));
    try testing.expect(!isValidHostname("hostname-"));
    try testing.expect(!isValidHostname("host name"));
    try testing.expect(!isValidHostname("host_name"));
    try testing.expect(!isValidHostname("host@domain"));
    try testing.expect(!isValidHostname("host:port"));

    // Too long
    const long_host = "a" ** 254;
    try testing.expect(!isValidHostname(long_host));
}

test "user validation - valid cases" {
    const testing = std.testing;
    try testing.expect(isValidUser("user"));
    try testing.expect(isValidUser("deploy"));
    try testing.expect(isValidUser("test-user"));
    try testing.expect(isValidUser("user_name"));
    try testing.expect(isValidUser("user.name"));
    try testing.expect(isValidUser("user123"));
    try testing.expect(isValidUser("a"));
}

test "user validation - complex realistic cases" {
    const testing = std.testing;
    try testing.expect(isValidUser("git"));
    try testing.expect(isValidUser("ubuntu"));
    try testing.expect(isValidUser("root"));
    try testing.expect(isValidUser("service.account"));
    try testing.expect(isValidUser("user-with-dashes"));
}

test "user validation - invalid cases" {
    const testing = std.testing;
    try testing.expect(!isValidUser(""));
    try testing.expect(!isValidUser("user name"));
    try testing.expect(!isValidUser("user@domain"));
    try testing.expect(!isValidUser("user:group"));
    try testing.expect(!isValidUser("user\nname"));

    // Too long
    const long_user = "a" ** 65;
    try testing.expect(!isValidUser(long_user));
}

test "cache key validation - hostname format" {
    const testing = std.testing;
    try testing.expect(isValidCacheKey("example.com"));
    try testing.expect(isValidCacheKey("sub.example.com"));
    try testing.expect(isValidCacheKey("192.168.1.1"));
    try testing.expect(isValidCacheKey("[::1]"));
    try testing.expect(!isValidCacheKey(""));
    try testing.expect(!isValidCacheKey(".invalid.com"));
}

test "cache key validation - user@hostname format" {
    const testing = std.testing;
    try testing.expect(isValidCacheKey("user@example.com"));
    try testing.expect(isValidCacheKey("deploy@prod.server.com"));
    try testing.expect(isValidCacheKey("test-user@192.168.1.1"));
    try testing.expect(isValidCacheKey("user_name@host.domain.org"));
    try testing.expect(isValidCacheKey("git@github.com"));
    try testing.expect(isValidCacheKey("ubuntu@[::1]"));
    try testing.expect(!isValidCacheKey("@example.com"));
    try testing.expect(!isValidCacheKey("user@"));
    try testing.expect(!isValidCacheKey("user@@host"));
    try testing.expect(!isValidCacheKey("user@.invalid.com"));
}
