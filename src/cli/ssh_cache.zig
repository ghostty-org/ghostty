const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const xdg = @import("../os/xdg.zig");
const args = @import("args.zig");
const Action = @import("ghostty.zig").Action;
pub const Entry = @import("ssh-cache/Entry.zig");
pub const DiskCache = @import("ssh-cache/DiskCache.zig");

pub const Options = struct {
    clear: bool = false,
    add: ?[]const u8 = null,
    remove: ?[]const u8 = null,
    host: ?[]const u8 = null,
    @"expire-days": ?u32 = null,

    pub fn deinit(self: *Options) void {
        _ = self;
    }

    pub fn help(self: Options) !void {
        _ = self;
        return Action.help_error;
    }
};

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
/// Only one of `--clear`, `--add`, `--remove`, or `--host` can be specified.
/// If multiple are specified, one of the actions will be executed but
/// it isn't guaranteed which one. This is entirely unsafe so you should split
/// multiple actions into separate commands.
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

    // Setup our disk cache to the standard location
    const cache_path = try DiskCache.defaultPath(alloc, "ghostty");
    const cache: DiskCache = .{ .path = cache_path };

    if (opts.clear) {
        try cache.clear();
        try stdout.print("Cache cleared.\n", .{});
        return 0;
    }

    if (opts.add) |host| {
        const result = cache.add(alloc, host) catch |err| switch (err) {
            DiskCache.Error.HostnameIsInvalid => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            DiskCache.Error.CacheIsLocked => {
                try stderr.print("Error: Cache is busy, try again\n", .{});
                return 1;
            },
            else => {
                try stderr.print(
                    "Error: Unable to add '{s}' to cache. Error: {}\n",
                    .{ host, err },
                );
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
        cache.remove(alloc, host) catch |err| switch (err) {
            DiskCache.Error.HostnameIsInvalid => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            DiskCache.Error.CacheIsLocked => {
                try stderr.print("Error: Cache is busy, try again\n", .{});
                return 1;
            },
            else => {
                try stderr.print(
                    "Error: Unable to remove '{s}' from cache. Error: {}\n",
                    .{ host, err },
                );
                return 1;
            },
        };
        try stdout.print("Removed '{s}' from cache.\n", .{host});
        return 0;
    }

    if (opts.host) |host| {
        const cached = cache.contains(alloc, host) catch |err| switch (err) {
            error.HostnameIsInvalid => {
                try stderr.print("Error: Invalid hostname format '{s}'\n", .{host});
                try stderr.print("Expected format: hostname or user@hostname\n", .{});
                return 1;
            },
            else => {
                try stderr.print(
                    "Error: Unable to check host '{s}' in cache. Error: {}\n",
                    .{ host, err },
                );
                return 1;
            },
        };

        if (cached) {
            try stdout.print(
                "'{s}' has Ghostty terminfo installed.\n",
                .{host},
            );
            return 0;
        } else {
            try stdout.print(
                "'{s}' does not have Ghostty terminfo installed.\n",
                .{host},
            );
            return 1;
        }
    }

    // Default action: list all hosts
    var entries = try cache.list(alloc);
    defer DiskCache.deinitEntries(alloc, &entries);
    try listEntries(alloc, &entries, stdout);
    return 0;
}

fn listEntries(
    alloc: Allocator,
    entries: *const std.StringHashMap(Entry),
    writer: anytype,
) !void {
    if (entries.count() == 0) {
        try writer.print("No hosts in cache.\n", .{});
        return;
    }

    // Sort entries by hostname for consistent output
    var items = std.ArrayList(Entry).init(alloc);
    defer items.deinit();

    var iter = entries.iterator();
    while (iter.next()) |kv| {
        try items.append(kv.value_ptr.*);
    }

    std.mem.sort(Entry, items.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
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

test {
    _ = DiskCache;
    _ = Entry;
}
