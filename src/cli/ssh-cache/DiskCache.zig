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

/// The IO interface used for filesystem operations.
io: std.Io,

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
    io: std.Io,
    env: *const std.process.Environ.Map,
    program: []const u8,
) DefaultPathError![]const u8 {
    const state_dir: []const u8 = xdg.state(
        alloc,
        io,
        env,
        .{ .subdir = program },
    ) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.XdgLookupFailed,
    };
    defer alloc.free(state_dir);
    return try std.Io.Dir.path.join(alloc, &.{ state_dir, "ssh_cache" });
}

/// Clear all cache data stored in the disk cache.
/// This removes the cache file from disk, effectively clearing all cached
/// SSH terminfo entries.
pub fn clear(self: DiskCache) !void {
    std.Io.Dir.cwd().deleteFile(self.io, self.path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

pub const AddResult = enum { added, updated };

pub const AddError = std.Io.Dir.CreateDirError ||
    std.Io.Dir.StatFileError ||
    std.Io.File.OpenError ||
    std.Io.File.SetPermissionsError ||
    std.Io.Reader.LimitedAllocError ||
    FixupPermissionsError ||
    ReadEntriesError ||
    WriteCacheFileError ||
    Error;

/// Add or update a hostname entry in the cache.
/// Returns AddResult.added for new entries or AddResult.updated for existing ones.
/// The cache file is created if it doesn't exist with secure permissions (0600).
pub fn add(
    self: *const DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) AddError!AddResult {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

    // Create cache directory if needed
    if (std.Io.Dir.path.dirname(self.path)) |dir| {
        std.Io.Dir.cwd().createDirPath(self.io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    // Open or create cache file with secure permissions
    const file = std.Io.Dir.createFileAbsolute(self.io, self.path, .{
        .read = true,
        .truncate = false,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => blk: {
            const existing_file = try std.Io.Dir.openFileAbsolute(
                self.io,
                self.path,
                .{ .mode = .read_write },
            );
            errdefer existing_file.close(self.io);
            try fixupPermissions(existing_file, self.io);
            break :blk existing_file;
        },
        else => return err,
    };
    defer file.close(self.io);

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(self.io, .exclusive) catch return error.CacheIsLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock(self.io);

    var entries = try readEntries(alloc, file, self.io);
    defer deinitEntries(alloc, &entries);

    const now = std.Io.Timestamp.now(self.io, .real).toSeconds();

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
            .timestamp = now,
            .terminfo_version = terminfo_copy,
        };
        break :add .added;
    } else update: {
        // Update timestamp for existing entry
        gop.value_ptr.timestamp = now;
        break :update .updated;
    };

    try self.writeCacheFile(entries, null);
    return result;
}

pub const RemoveError = std.Io.File.OpenError ||
    FixupPermissionsError ||
    ReadEntriesError ||
    WriteCacheFileError ||
    Error;

/// Remove a hostname entry from the cache.
/// No error is returned if the hostname doesn't exist or the cache file is missing.
pub fn remove(
    self: *const DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) RemoveError!void {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

    // Open our file
    const file = std.Io.Dir.openFileAbsolute(
        self.io,
        self.path,
        .{ .mode = .read_write },
    ) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer file.close(self.io);
    try fixupPermissions(file, self.io);

    // Lock
    // Causes a compile failure in the Zig std library on Windows, see:
    // https://github.com/ziglang/zig/issues/18430
    if (comptime builtin.os.tag != .windows) _ = file.tryLock(self.io, .exclusive) catch return error.CacheIsLocked;
    defer if (comptime builtin.os.tag != .windows) file.unlock(self.io);

    // Read existing entries
    var entries = try readEntries(alloc, file, self.io);
    defer deinitEntries(alloc, &entries);

    // Remove the entry if it exists and ensure we free the memory
    if (entries.fetchRemove(hostname)) |kv| {
        assert(kv.key.ptr == kv.value.hostname.ptr);
        alloc.free(kv.value.hostname);
        alloc.free(kv.value.terminfo_version);
    }

    try self.writeCacheFile(entries, null);
}

pub const ContainsError = std.Io.File.OpenError ||
    ReadEntriesError ||
    error{HostnameIsInvalid};

/// Check if a hostname exists in the cache.
/// Returns false if the cache file doesn't exist.
pub fn contains(
    self: *const DiskCache,
    alloc: Allocator,
    hostname: []const u8,
) ContainsError!bool {
    if (!isValidCacheKey(hostname)) return error.HostnameIsInvalid;

    // Open our file
    const file = std.Io.Dir.openFileAbsolute(
        self.io,
        self.path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close(self.io);

    // Read existing entries
    var entries = try readEntries(alloc, file, self.io);
    defer deinitEntries(alloc, &entries);

    return entries.contains(hostname);
}

pub const FixupPermissionsError = (std.Io.File.StatError || std.Io.File.SetPermissionsError);

fn fixupPermissions(file: std.Io.File, io: std.Io) FixupPermissionsError!void {
    // Windows does not support chmod
    if (comptime builtin.os.tag == .windows) return;

    // Ensure file has correct permissions (readable/writable by
    // owner only)
    const stat = try file.stat(io);
    if (@intFromEnum(stat.permissions) & 0o777 != 0o600) {
        try file.setPermissions(io, .fromMode(0o600));
    }
}

pub const WriteCacheFileError = std.Io.Dir.OpenError ||
    std.Io.Dir.CreateFileAtomicError ||
    std.Io.File.Writer.Error ||
    std.Io.File.Atomic.ReplaceError ||
    Entry.FormatError ||
    error{InvalidCachePath};

fn writeCacheFile(
    self: *const DiskCache,
    entries: std.StringHashMap(Entry),
    expire_days: ?u32,
) WriteCacheFileError!void {
    const cache_dir = std.Io.Dir.path.dirname(self.path) orelse return error.InvalidCachePath;
    const cache_basename = std.Io.Dir.path.basename(self.path);

    var dir = try std.Io.Dir.cwd().openDir(self.io, cache_dir, .{});
    defer dir.close(self.io);

    var buf: [1024]u8 = undefined;
    var atomic_file = try dir.createFileAtomic(self.io, cache_basename, .{
        .permissions = .fromMode(0o600),
        .make_path = true,
        .replace = true,
    });
    defer atomic_file.deinit(self.io);

    var file_writer = atomic_file.file.writer(self.io, &buf);

    var iter = entries.iterator();
    while (iter.next()) |kv| {
        // Only write non-expired entries
        if (kv.value_ptr.isExpired(self.io, expire_days)) continue;
        try kv.value_ptr.format(&file_writer.interface);
    }
    try file_writer.flush();

    try atomic_file.replace(self.io);
}

/// List all entries in the cache.
/// The returned HashMap must be freed using `deinitEntries`.
/// Returns an empty map if the cache file doesn't exist.
pub fn list(
    self: *const DiskCache,
    alloc: Allocator,
) !std.StringHashMap(Entry) {
    // Open our file
    const file = std.Io.Dir.openFileAbsolute(
        self.io,
        self.path,
        .{},
    ) catch |err| switch (err) {
        error.FileNotFound => return .init(alloc),
        else => return err,
    };
    defer file.close(self.io);
    return readEntries(alloc, file, self.io);
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

pub const ReadEntriesError = std.mem.Allocator.Error || std.Io.Reader.LimitedAllocError;

fn readEntries(
    alloc: Allocator,
    file: std.Io.File,
    io: std.Io,
) ReadEntriesError!std.StringHashMap(Entry) {
    var read_buf: [4096]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    const content = try reader.interface.allocRemaining(
        alloc,
        .limited(MAX_CACHE_SIZE),
    );
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
    if (std.Io.net.Ip6Address.parse(host, 0)) |_| {
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
    const io = std.testing.io;

    var env: std.process.Environ.Map = .init(alloc);
    defer env.deinit();

    const path = try DiskCache.defaultPath(
        alloc,
        io,
        &env,
        "ghostty",
    );
    defer alloc.free(path);
    try testing.expect(path.len > 0);
}

test "disk cache clear" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = std.testing.io;

    // Create our path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    {
        var file = try tmp.dir.createFile(io, "cache", .{});
        defer file.close(io);
        var file_writer = file.writer(&buf);
        try file_writer.interface.writeAll("HELLO!");
    }
    const path = try tmp.dir.realPathFileAlloc(io, alloc, "cache");
    defer alloc.free(path);

    // Setup our cache
    const cache: DiskCache = .{ .io = io, .path = path };
    try cache.clear();

    // Verify the file is gone
    try testing.expectError(
        error.FileNotFound,
        tmp.dir.openFile(io, "cache", .{}),
    );
}

test "disk cache operations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = std.testing.io;

    // Create our path
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    {
        var file = try tmp.dir.createFile(io, "cache", .{});
        defer file.close(io);
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;
        try writer.writeAll("HELLO!");
        try writer.flush();
    }
    const path = try tmp.dir.realPathFileAlloc(io, alloc, "cache");
    defer alloc.free(path);

    // Setup our cache
    const cache: DiskCache = .{ .io = io, .path = path };
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

test "disk cache cleans up temp files" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = std.testing.io;

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    const tmp_path = try tmp.dir.realPathFileAlloc(io, alloc, ".");
    defer alloc.free(tmp_path);
    const cache_path = try std.Io.Dir.path.join(alloc, &.{ tmp_path, "cache" });
    defer alloc.free(cache_path);

    const cache: DiskCache = .{ .io = io, .path = cache_path };
    try testing.expectEqual(AddResult.added, try cache.add(alloc, "example.com"));
    try testing.expectEqual(AddResult.added, try cache.add(alloc, "example.org"));

    // Verify only the cache file exists and no temp files left behind
    var count: usize = 0;
    var iter = tmp.dir.iterate();
    while (try iter.next(io)) |entry| {
        count += 1;
        try testing.expectEqualStrings("cache", entry.name);
    }
    try testing.expectEqual(1, count);
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
