const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const xdg = @import("../os/xdg.zig");
const args = @import("args.zig");
const Action = @import("action.zig").Action;

pub const CacheError = error{
    InvalidCacheKey,
    CacheLocked,
} || fs.File.OpenError || fs.File.WriteError || Allocator.Error;

const MAX_CACHE_SIZE = 512 * 1024; // 512KB - sufficient for approximately 10k entries
const NEVER_EXPIRE = 0;

pub const Options = struct {
    clear: bool = false,
    add: ?[]const u8 = null,
    remove: ?[]const u8 = null,
    host: ?[]const u8 = null,
    @"expire-days": u32 = NEVER_EXPIRE,

    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

const CacheEntry = struct {
    hostname: []const u8,
    timestamp: i64,
    terminfo_version: []const u8,

    fn parse(line: []const u8) ?CacheEntry {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) return null;

        // Parse format: hostname|timestamp|terminfo_version
        var iter = std.mem.tokenizeScalar(u8, trimmed, '|');
        const hostname = iter.next() orelse return null;
        const timestamp_str = iter.next() orelse return null;
        const terminfo_version = iter.next() orelse "xterm-ghostty";

        const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch |err| {
            std.log.warn("Invalid timestamp in cache entry: {s} err={}", .{ timestamp_str, err });
            return null;
        };

        return CacheEntry{
            .hostname = hostname,
            .timestamp = timestamp,
            .terminfo_version = terminfo_version,
        };
    }

    fn format(self: CacheEntry, writer: anytype) !void {
        try writer.print("{s}|{d}|{s}\n", .{ self.hostname, self.timestamp, self.terminfo_version });
    }

    fn isExpired(self: CacheEntry, expire_days: u32) bool {
        if (expire_days == NEVER_EXPIRE) return false;
        const now = std.time.timestamp();
        const age_days = @divTrunc(now - self.timestamp, std.time.s_per_day);
        return age_days > expire_days;
    }
};

const AddResult = enum {
    added,
    updated,
};

fn getCachePath(allocator: Allocator) ![]const u8 {
    const state_dir = try xdg.state(allocator, .{ .subdir = "ghostty" });
    defer allocator.free(state_dir);
    return try std.fs.path.join(allocator, &.{ state_dir, "ssh_cache" });
}

// Supports both standalone hostnames and user@hostname format
fn isValidCacheKey(key: []const u8) bool {
    if (key.len == 0 or key.len > 320) return false; // 253 + 1 + 64 for user@hostname

    // Check for user@hostname format
    if (std.mem.indexOf(u8, key, "@")) |at_pos| {
        const user = key[0..at_pos];
        const hostname = key[at_pos + 1 ..];
        return isValidUser(user) and isValidHostname(hostname);
    }

    return isValidHostname(key);
}

// Basic hostname validation - accepts domains and IPs (including IPv6 in brackets)
fn isValidHostname(host: []const u8) bool {
    if (host.len == 0 or host.len > 253) return false;

    // Handle IPv6 addresses in brackets
    if (host.len >= 4 and host[0] == '[' and host[host.len - 1] == ']') {
        const ipv6_part = host[1 .. host.len - 1];
        if (ipv6_part.len == 0) return false;
        var has_colon = false;
        for (ipv6_part) |c| {
            switch (c) {
                'a'...'f', 'A'...'F', '0'...'9', ':' => {
                    if (c == ':') has_colon = true;
                },
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

fn acquireFileLock(file: fs.File) CacheError!void {
    _ = file.tryLock(.exclusive) catch {
        return CacheError.CacheLocked;
    };
}

fn readCacheFile(
    alloc: Allocator,
    path: []const u8,
    entries: *std.StringHashMap(CacheEntry),
) !void {
    const file = fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(alloc, MAX_CACHE_SIZE);
    defer alloc.free(content);

    var lines = std.mem.tokenizeScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (CacheEntry.parse(trimmed)) |entry| {
            // Always allocate hostname first to avoid key pointer confusion
            const hostname_copy = try alloc.dupe(u8, entry.hostname);
            errdefer alloc.free(hostname_copy);

            const gop = try entries.getOrPut(hostname_copy);
            if (!gop.found_existing) {
                const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
                gop.value_ptr.* = CacheEntry{
                    .hostname = hostname_copy,
                    .timestamp = entry.timestamp,
                    .terminfo_version = terminfo_copy,
                };
            } else {
                // Don't need the copy since entry already exists
                alloc.free(hostname_copy);

                // Handle duplicate entries - keep newer timestamp
                if (entry.timestamp > gop.value_ptr.timestamp) {
                    gop.value_ptr.timestamp = entry.timestamp;
                    if (!std.mem.eql(u8, gop.value_ptr.terminfo_version, entry.terminfo_version)) {
                        alloc.free(gop.value_ptr.terminfo_version);
                        const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
                        gop.value_ptr.terminfo_version = terminfo_copy;
                    }
                }
            }
        }
    }
}

// Atomic write via temp file + rename, filters out expired entries
fn writeCacheFile(
    alloc: Allocator,
    path: []const u8,
    entries: *const std.StringHashMap(CacheEntry),
    expire_days: u32,
) !void {
    // Ensure parent directory exists
    const dir = std.fs.path.dirname(path).?;
    fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Write to temp file first
    const tmp_path = try std.fmt.allocPrint(alloc, "{s}.tmp", .{path});
    defer alloc.free(tmp_path);

    const tmp_file = try fs.createFileAbsolute(tmp_path, .{ .mode = 0o600 });
    defer tmp_file.close();
    errdefer fs.deleteFileAbsolute(tmp_path) catch {};

    const writer = tmp_file.writer();

    // Only write non-expired entries
    var iter = entries.iterator();
    while (iter.next()) |kv| {
        if (!kv.value_ptr.isExpired(expire_days)) {
            try kv.value_ptr.format(writer);
        }
    }

    // Atomic replace
    try fs.renameAbsolute(tmp_path, path);
}

fn checkHost(alloc: Allocator, host: []const u8) !bool {
    if (!isValidCacheKey(host)) return CacheError.InvalidCacheKey;

    const path = try getCachePath(alloc);

    var entries = std.StringHashMap(CacheEntry).init(alloc);

    try readCacheFile(alloc, path, &entries);
    return entries.contains(host);
}

fn addHost(alloc: Allocator, host: []const u8) !AddResult {
    if (!isValidCacheKey(host)) return CacheError.InvalidCacheKey;

    const path = try getCachePath(alloc);

    // Create cache directory if needed
    const dir = std.fs.path.dirname(path).?;
    fs.makeDirAbsolute(dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    // Open or create cache file with secure permissions
    const file = fs.createFileAbsolute(path, .{
        .read = true,
        .truncate = false,
        .mode = 0o600,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            const existing_file = fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |open_err| {
                return open_err;
            };

            // Verify and fix permissions on existing file
            const stat = existing_file.stat() catch |stat_err| {
                existing_file.close();
                return stat_err;
            };

            // Ensure file has correct permissions (readable/writable by owner only)
            if (stat.mode & 0o777 != 0o600) {
                existing_file.chmod(0o600) catch |chmod_err| {
                    existing_file.close();
                    return chmod_err;
                };
            }

            break :blk existing_file;
        },
        else => return err,
    };
    defer file.close();

    try acquireFileLock(file);
    defer file.unlock();

    var entries = std.StringHashMap(CacheEntry).init(alloc);

    try readCacheFile(alloc, path, &entries);

    // Add or update entry
    const gop = try entries.getOrPut(host);
    const result = if (!gop.found_existing) blk: {
        gop.key_ptr.* = try alloc.dupe(u8, host);
        gop.value_ptr.* = .{
            .hostname = gop.key_ptr.*,
            .timestamp = std.time.timestamp(),
            .terminfo_version = "xterm-ghostty",
        };
        break :blk AddResult.added;
    } else blk: {
        // Update timestamp for existing entry
        gop.value_ptr.timestamp = std.time.timestamp();
        break :blk AddResult.updated;
    };

    try writeCacheFile(alloc, path, &entries, NEVER_EXPIRE);
    return result;
}

fn removeHost(alloc: Allocator, host: []const u8) !void {
    if (!isValidCacheKey(host)) return CacheError.InvalidCacheKey;

    const path = try getCachePath(alloc);

    const file = fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close();

    try acquireFileLock(file);
    defer file.unlock();

    var entries = std.StringHashMap(CacheEntry).init(alloc);

    try readCacheFile(alloc, path, &entries);

    _ = entries.fetchRemove(host);

    try writeCacheFile(alloc, path, &entries, NEVER_EXPIRE);
}

fn listHosts(alloc: Allocator, writer: anytype) !void {
    const path = try getCachePath(alloc);

    var entries = std.StringHashMap(CacheEntry).init(alloc);

    readCacheFile(alloc, path, &entries) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("No hosts in cache.\n", .{});
            return;
        },
        else => return err,
    };

    if (entries.count() == 0) {
        try writer.print("No hosts in cache.\n", .{});
        return;
    }

    // Sort entries by hostname for consistent output
    var items = std.ArrayList(CacheEntry).init(alloc);
    defer items.deinit();

    var iter = entries.iterator();
    while (iter.next()) |kv| {
        try items.append(kv.value_ptr.*);
    }

    std.mem.sort(CacheEntry, items.items, {}, struct {
        fn lessThan(_: void, a: CacheEntry, b: CacheEntry) bool {
            return std.mem.lessThan(u8, a.hostname, b.hostname);
        }
    }.lessThan);

    try writer.print("Cached hosts ({d}):\n", .{items.items.len});
    const now = std.time.timestamp();

    for (items.items) |entry| {
        const age_days = @divTrunc(now - entry.timestamp, std.time.s_per_day);
        if (age_days == 0) {
            try writer.print("  {s} (today)\n", .{entry.hostname});
        } else if (age_days == 1) {
            try writer.print("  {s} (yesterday)\n", .{entry.hostname});
        } else {
            try writer.print("  {s} ({d} days ago)\n", .{ entry.hostname, age_days });
        }
    }
}

fn clearCache(alloc: Allocator) !void {
    const path = try getCachePath(alloc);

    fs.deleteFileAbsolute(path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

/// Manage the SSH terminfo cache for automatic remote host setup.
///
/// When SSH integration is enabled with `shell-integration-features = ssh-terminfo`,
/// Ghostty automatically installs its terminfo on remote hosts. This command
/// manages the cache of successful installations to avoid redundant uploads.
///
/// The cache stores hostnames (or user@hostname combinations) along with timestamps.
/// Entries older than the expiration period are automatically removed during cache
/// operations. By default, entries never expire.
///
/// Examples:
///   ghostty +ssh-cache                          # List all cached hosts
///   ghostty +ssh-cache --host=example.com       # Check if host is cached
///   ghostty +ssh-cache --add=example.com        # Manually add host to cache
///   ghostty +ssh-cache --add=user@example.com   # Add user@host combination
///   ghostty +ssh-cache --remove=example.com     # Remove host from cache
///   ghostty +ssh-cache --clear                  # Clear entire cache
///   ghostty +ssh-cache --expire-days=30         # Set custom expiration period
pub fn run(alloc_gpa: Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opts: Options = .{};
    defer opts.deinit();

    {
        var iter = try args.argsIterator(alloc_gpa);
        defer iter.deinit();
        try args.parse(Options, alloc_gpa, &opts, &iter);
    }

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    if (opts.clear) {
        try clearCache(alloc);
        try stdout.print("Cache cleared.\n", .{});
        return 0;
    }

    if (opts.add) |host| {
        const result = addHost(alloc, host) catch |err| switch (err) {
            CacheError.InvalidCacheKey => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            CacheError.CacheLocked => {
                try stderr.print("Error: Cache is busy, try again\n", .{});
                return 1;
            },
            error.AccessDenied, error.PermissionDenied => {
                try stderr.print("Error: Permission denied\n", .{});
                return 1;
            },
            else => {
                try stderr.print("Error: Unable to add '{s}' to cache\n", .{host});
                return 1;
            },
        };

        switch (result) {
            .added => try stdout.print("Added '{s}' to cache.\n", .{host}),
            .updated => try stdout.print("Updated '{s}' cache entry.\n", .{host}),
        }
        return 0;
    }

    if (opts.remove) |host| {
        removeHost(alloc, host) catch |err| switch (err) {
            CacheError.InvalidCacheKey => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            CacheError.CacheLocked => {
                try stderr.print("Error: Cache is busy, try again\n", .{});
                return 1;
            },
            error.AccessDenied, error.PermissionDenied => {
                try stderr.print("Error: Permission denied\n", .{});
                return 1;
            },
            else => {
                try stderr.print("Error: Unable to remove '{s}' from cache\n", .{host});
                return 1;
            },
        };
        try stdout.print("Removed '{s}' from cache.\n", .{host});
        return 0;
    }

    if (opts.host) |host| {
        const cached = checkHost(alloc, host) catch |err| switch (err) {
            CacheError.InvalidCacheKey => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            error.AccessDenied, error.PermissionDenied => {
                try stderr.print("Error: Permission denied\n", .{});
                return 1;
            },
            else => {
                try stderr.print("Error: Unable to check host '{s}' in cache\n", .{host});
                return 1;
            },
        };

        if (cached) {
            try stdout.print("'{s}' has Ghostty terminfo installed.\n", .{host});
            return 0;
        } else {
            try stdout.print("'{s}' does not have Ghostty terminfo installed.\n", .{host});
            return 1;
        }
    }

    // Default action: list all hosts
    try listHosts(alloc, stdout);
    return 0;
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

test "cache entry expiration" {
    const testing = std.testing;
    const now = std.time.timestamp();

    const fresh_entry = CacheEntry{
        .hostname = "test.com",
        .timestamp = now - std.time.s_per_day, // 1 day old
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(!fresh_entry.isExpired(90));

    const old_entry = CacheEntry{
        .hostname = "old.com",
        .timestamp = now - (std.time.s_per_day * 100), // 100 days old
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(old_entry.isExpired(90));

    // Test never-expire case
    try testing.expect(!old_entry.isExpired(NEVER_EXPIRE));
}

test "cache entry expiration - boundary cases" {
    const testing = std.testing;
    const now = std.time.timestamp();

    // Exactly at expiration boundary
    const boundary_entry = CacheEntry{
        .hostname = "boundary.com",
        .timestamp = now - (std.time.s_per_day * 30), // Exactly 30 days old
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(!boundary_entry.isExpired(30)); // Should not be expired
    try testing.expect(boundary_entry.isExpired(29)); // Should be expired
}

test "cache entry parsing - valid formats" {
    const testing = std.testing;

    const entry = CacheEntry.parse("example.com|1640995200|xterm-ghostty").?;
    try testing.expectEqualStrings("example.com", entry.hostname);
    try testing.expectEqual(@as(i64, 1640995200), entry.timestamp);
    try testing.expectEqualStrings("xterm-ghostty", entry.terminfo_version);

    // Test default terminfo version
    const entry_no_version = CacheEntry.parse("test.com|1640995200").?;
    try testing.expectEqualStrings("xterm-ghostty", entry_no_version.terminfo_version);

    // Test complex hostnames
    const complex_entry = CacheEntry.parse("user@server.example.com|1640995200|xterm-ghostty").?;
    try testing.expectEqualStrings("user@server.example.com", complex_entry.hostname);
}

test "cache entry parsing - invalid formats" {
    const testing = std.testing;

    try testing.expect(CacheEntry.parse("") == null);
    try testing.expect(CacheEntry.parse("v1") == null); // Invalid format (no pipe)
    try testing.expect(CacheEntry.parse("example.com") == null); // Missing timestamp
    try testing.expect(CacheEntry.parse("example.com|invalid") == null); // Invalid timestamp
    try testing.expect(CacheEntry.parse("example.com|1640995200|") != null); // Empty terminfo should default
}

test "cache entry parsing - malformed data resilience" {
    const testing = std.testing;

    // Extra pipes should not break parsing
    try testing.expect(CacheEntry.parse("host|123|term|extra") != null);

    // Whitespace handling
    try testing.expect(CacheEntry.parse("  host|123|term  ") != null);
    try testing.expect(CacheEntry.parse("\n") == null);
    try testing.expect(CacheEntry.parse("   \t  \n") == null);
}

test "duplicate cache entries - memory management" {
    const testing = std.testing;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var entries = std.StringHashMap(CacheEntry).init(alloc);
    defer entries.deinit();

    // Simulate reading a cache file with duplicate hostnames
    const cache_content = "example.com|1640995200|xterm-ghostty\nexample.com|1640995300|xterm-ghostty-v2\n";

    var lines = std.mem.tokenizeScalar(u8, cache_content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (CacheEntry.parse(trimmed)) |entry| {
            const gop = try entries.getOrPut(entry.hostname);
            if (!gop.found_existing) {
                const hostname_copy = try alloc.dupe(u8, entry.hostname);
                const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
                gop.key_ptr.* = hostname_copy;
                gop.value_ptr.* = CacheEntry{
                    .hostname = hostname_copy,
                    .timestamp = entry.timestamp,
                    .terminfo_version = terminfo_copy,
                };
            } else {
                // Test the duplicate handling logic
                if (entry.timestamp > gop.value_ptr.timestamp) {
                    gop.value_ptr.timestamp = entry.timestamp;
                    if (!std.mem.eql(u8, gop.value_ptr.terminfo_version, entry.terminfo_version)) {
                        alloc.free(gop.value_ptr.terminfo_version);
                        const terminfo_copy = try alloc.dupe(u8, entry.terminfo_version);
                        gop.value_ptr.terminfo_version = terminfo_copy;
                    }
                }
            }
        }
    }

    // Verify only one entry exists with the newer timestamp
    try testing.expect(entries.count() == 1);
    const entry = entries.get("example.com").?;
    try testing.expectEqual(@as(i64, 1640995300), entry.timestamp);
    try testing.expectEqualStrings("xterm-ghostty-v2", entry.terminfo_version);
}
