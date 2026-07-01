const std = @import("std");
const fs = std.fs;
const Allocator = std.mem.Allocator;
const args = @import("args.zig");
const global = @import("../global.zig");
const Action = @import("ghostty.zig").Action;
const Duration = @import("../config.zig").Config.Duration;
pub const Entry = @import("ssh-cache/Entry.zig");
pub const DiskCache = @import("ssh-cache/DiskCache.zig");

pub const Options = struct {
    clear: bool = false,
    add: ?[]const u8 = null,
    remove: ?[]const u8 = null,
    prune: ?Duration = null,

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
/// The `+ssh` action installs Ghostty's terminfo on remote hosts and records
/// each success in this cache so it doesn't re-upload on later connections.
/// (`+ssh` runs automatically from the shell integration when
/// `shell-integration-features` includes `ssh-terminfo`.) This command
/// inspects and maintains that cache.
///
/// The cache stores destinations (a hostname or user@hostname) along with
/// timestamps.
///
/// A positional destination queries the cache: `user@hostname` shows that
/// exact entry, while a bare `hostname` shows every cached entry for that
/// host regardless of user. With no destination and no action, the entire
/// cache is listed. A query that matches nothing exits 1.
///
/// At most one action (`--clear`, `--add`, `--remove`, or `--prune`) may be
/// specified, and not together with a positional destination; combining them
/// is an error.
///
/// `--prune` takes a duration with unit suffixes (`s`, `m`, `h`, `d`, `w`,
/// `y`) and removes every entry older than it, e.g. `--prune=30d`,
/// `--prune=6h`, `--prune=1y`.
///
/// Examples:
///   ghostty +ssh-cache                           # List all cached destinations
///   ghostty +ssh-cache user@example.com          # Show that destination
///   ghostty +ssh-cache example.com               # Show all users on that host
///   ghostty +ssh-cache --add=user@example.com    # Manually add a destination
///   ghostty +ssh-cache --remove=user@example.com # Remove a destination
///   ghostty +ssh-cache --prune=30d               # Remove entries older than 30 days
///   ghostty +ssh-cache --clear                   # Clear entire cache
pub fn run(alloc_gpa: Allocator) !u8 {
    var arena = std.heap.ArenaAllocator.init(alloc_gpa);
    defer arena.deinit();
    const alloc = arena.allocator();

    var opts: Options = .{};
    defer opts.deinit();

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_file: std.Io.File = .stdout();
    var stdout_writer = stdout_file.writer(global.io(), &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_file: std.Io.File = .stderr();
    var stderr_writer = stderr_file.writer(global.io(), &stderr_buffer);
    const stderr = &stderr_writer.interface;

    // The cache is queried by a positional destination (`user@host` or a
    // bare `host`). `args.parse` rejects non-`--` tokens, so we lift the
    // positional out here and parse only the remaining flags. `--host=X`
    // is accepted as a deprecated spelling of the positional (it was the
    // original shipped flag name).
    var query: ?[]const u8 = null;
    var flags: std.ArrayList([]const u8) = .empty;
    {
        var iter = try args.argsIterator(alloc_gpa, global.args());
        defer iter.deinit();
        while (iter.next()) |arg| {
            const is_host_flag = std.mem.startsWith(u8, arg, "--host=");
            if (is_host_flag) {
                try stderr.print(
                    "Warning: --host is deprecated; pass the destination " ++
                        "directly, e.g. `ghostty +ssh-cache {s}`.\n",
                    .{arg["--host=".len..]},
                );
            }
            const dest: ?[]const u8 = if (is_host_flag)
                arg["--host=".len..]
            else if (!std.mem.startsWith(u8, arg, "-"))
                arg
            else
                null;

            if (dest) |d| {
                if (query != null) {
                    try stderr.print(
                        "Error: only one destination may be specified.\n",
                        .{},
                    );
                    stderr.flush() catch {};
                    return 2;
                }
                query = try alloc.dupe(u8, d);
            } else {
                try flags.append(alloc, try alloc.dupe(u8, arg));
            }
        }
    }

    {
        var iter = args.sliceIterator(flags.items);
        args.parse(Options, alloc_gpa, &opts, &iter) catch |err| switch (err) {
            error.InvalidField => {
                try stderr.print("Error: unknown flag.\n", .{});
                stderr.flush() catch {};
                return 2;
            },
            error.InvalidValue, error.ValueRequired => {
                try stderr.print("Error: invalid flag value.\n", .{});
                stderr.flush() catch {};
                return 2;
            },
            else => return err,
        };
    }

    const result = runInner(alloc, opts, query, stdout, stderr);

    // Flushing *shouldn't* fail but...
    stdout.flush() catch {};
    stderr.flush() catch {};
    return result;
}

pub fn runInner(
    alloc: Allocator,
    opts: Options,
    query: ?[]const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    // At most one action may be specified, and a query (positional
    // destination) is itself an action.
    const action_count =
        @as(usize, @intFromBool(opts.clear)) +
        @intFromBool(opts.add != null) +
        @intFromBool(opts.remove != null) +
        @intFromBool(opts.prune != null) +
        @intFromBool(query != null);
    if (action_count > 1) {
        try stderr.print(
            "Error: only one of a destination, --clear, --add, --remove, " ++
                "or --prune may be specified.\n",
            .{},
        );
        return 2;
    }

    // Setup our disk cache to the standard location
    const cache_path = try DiskCache.defaultPath(alloc, "ghostty");
    const cache: DiskCache = .{ .path = cache_path };

    if (opts.clear) {
        try cache.clear();
        return 0;
    }

    if (opts.add) |dest| {
        cache.add(
            alloc,
            dest,
            std.Io.Timestamp.now(global.io(), .real).toSeconds(),
        ) catch |err| switch (err) {
            error.InvalidCacheKey => {
                try stderr.print(
                    "Error: Invalid destination '{s}' (expected hostname or user@hostname)\n",
                    .{dest},
                );
                return 2;
            },
            else => {
                try stderr.print(
                    "Error: Unable to add '{s}' to cache. Error: {}\n",
                    .{ dest, err },
                );
                return 1;
            },
        };
        return 0;
    }

    if (opts.remove) |dest| {
        const removed = cache.remove(alloc, dest) catch |err| switch (err) {
            error.InvalidCacheKey => {
                try stderr.print(
                    "Error: Invalid destination '{s}' (expected hostname or user@hostname)\n",
                    .{dest},
                );
                return 2;
            },
            else => {
                try stderr.print(
                    "Error: Unable to remove '{s}' from cache. Error: {}\n",
                    .{ dest, err },
                );
                return 1;
            },
        };
        // Silence on success; a no-op removal is an error (exit 1).
        if (!removed) {
            try stderr.print("Error: '{s}' is not in the cache.\n", .{dest});
            return 1;
        }
        return 0;
    }

    if (opts.prune) |max_age| {
        const max_age_s = max_age.duration / std.time.ns_per_s;
        if (max_age_s == 0) {
            try stderr.print(
                "Error: --prune requires a duration of at least one second.\n",
                .{},
            );
            return 2;
        }
        const pruned = cache.prune(alloc, max_age_s) catch |err| {
            try stderr.print("Error: Unable to prune cache. Error: {}\n", .{err});
            return 1;
        };
        try stdout.print("Pruned cache entries: {d}\n", .{pruned});
        return 0;
    }

    var entries = try cache.list(alloc);
    defer DiskCache.deinitEntries(alloc, &entries);

    // A positional query filters the listing: an exact `user@host` match,
    // or every entry on a bare `host`.
    if (query) |q| {
        if (!DiskCache.isValidCacheKey(q)) {
            try stderr.print(
                "Error: Invalid destination '{s}' (expected hostname or user@hostname)\n",
                .{q},
            );
            return 2;
        }

        var matches: std.StringHashMap(Entry) = .init(alloc);
        defer matches.deinit();
        var iter = entries.iterator();
        while (iter.next()) |kv| {
            const key = kv.key_ptr.*;
            if (matchesQuery(key, q)) try matches.put(key, kv.value_ptr.*);
        }

        if (matches.count() == 0) return 1;
        try listEntries(alloc, &matches, stdout);
        return 0;
    }

    // List all destinations by default.
    try listEntries(alloc, &entries, stdout);
    return 0;
}

fn listEntries(
    alloc: Allocator,
    entries: *const std.StringHashMap(Entry),
    writer: *std.Io.Writer,
) !void {
    if (entries.count() == 0) return;

    // Sort entries by hostname for consistent output
    var items: std.ArrayList(Entry) = .empty;
    defer items.deinit(alloc);

    var iter = entries.iterator();
    while (iter.next()) |kv| {
        try items.append(alloc, kv.value_ptr.*);
    }

    std.mem.sort(Entry, items.items, {}, struct {
        fn lessThan(_: void, a: Entry, b: Entry) bool {
            return std.mem.lessThan(u8, a.hostname, b.hostname);
        }
    }.lessThan);

    // Align the timestamp column by padding destinations to the widest.
    var widest: usize = 0;
    for (items.items) |entry| {
        widest = @max(widest, entry.hostname.len);
    }

    const now = std.Io.Timestamp.now(global.io(), .real).toSeconds();
    for (items.items) |entry| {
        try writer.print("{s}", .{entry.hostname});
        try writer.splatByteAll(' ', widest - entry.hostname.len + 2);

        var iso_buf: [20]u8 = undefined;
        var age_buf: [32]u8 = undefined;
        try writer.print("{s} ({s})\n", .{
            formatTimestamp(&iso_buf, entry.timestamp),
            relativeAge(&age_buf, now, entry.timestamp),
        });
    }
}

/// Whether a cache `key` matches a positional `query`. A `user@host` query
/// (containing `@`) matches one exact key; a bare `host` query matches every
/// key on that host regardless of user, comparing against the key's host
/// component (everything after its first `@`, or the whole key if userless).
fn matchesQuery(key: []const u8, query: []const u8) bool {
    if (std.mem.indexOfScalar(u8, query, '@') != null) {
        return std.mem.eql(u8, key, query);
    }

    const at = std.mem.indexOfScalar(u8, key, '@');
    const host = if (at) |i| key[i + 1 ..] else key;
    return std.mem.eql(u8, host, query);
}

test matchesQuery {
    const testing = std.testing;

    // Exact user@host: only the identical key.
    try testing.expect(matchesQuery("user@example.com", "user@example.com"));
    try testing.expect(!matchesQuery("root@example.com", "user@example.com"));
    try testing.expect(!matchesQuery("example.com", "user@example.com"));

    // Bare host: every key on that host, plus a keyless entry for it.
    try testing.expect(matchesQuery("user@example.com", "example.com"));
    try testing.expect(matchesQuery("root@example.com", "example.com"));
    try testing.expect(matchesQuery("example.com", "example.com"));
    try testing.expect(!matchesQuery("user@other.com", "example.com"));
}

/// Format a Unix timestamp as an ISO-8601 UTC string
/// (`YYYY-MM-DDTHH:MM:SSZ`) into `buf`, which must be at least 20 bytes.
/// Out-of-range input is clamped so this can't crash on a garbage cache line.
fn formatTimestamp(buf: []u8, timestamp: i64) []const u8 {
    // Clamp to [epoch, last second of 9999-12-31Z]: `std.time.epoch`
    // accumulates the year in a `u16` (panics beyond that), and the buffer
    // only fits a 4-digit year.
    const secs: u64 = @intCast(std.math.clamp(timestamp, 0, 253402300799));

    const epoch = std.time.epoch;
    const epoch_secs: epoch.EpochSeconds = .{ .secs = secs };
    const day = epoch_secs.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const ds = epoch_secs.getDaySeconds();
    return std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch unreachable;
}

test formatTimestamp {
    const testing = std.testing;
    var buf: [20]u8 = undefined;

    try testing.expectEqualStrings(
        "2026-05-05T22:49:33Z",
        formatTimestamp(&buf, 1778021373),
    );

    // Epoch.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        formatTimestamp(&buf, 0),
    );

    // Out-of-range inputs clamp instead of overflowing the [20]u8 /
    // panicking inside std: negatives floor at the epoch, huge values cap
    // at the last second of year 9999.
    try testing.expectEqualStrings(
        "1970-01-01T00:00:00Z",
        formatTimestamp(&buf, -5),
    );
    try testing.expectEqualStrings(
        "9999-12-31T23:59:59Z",
        formatTimestamp(&buf, std.math.maxInt(i64)),
    );
}

/// Format the age of `timestamp` (relative to `now`, both Unix seconds)
/// as a coarse relative time into `buf`, e.g. "2w ago". Uses `Duration`'s
/// unit vocabulary but keeps only the single largest unit for scannability.
/// A non-positive age (timestamp at or after `now`) is "now".
fn relativeAge(buf: []u8, now: i64, timestamp: i64) []const u8 {
    // Saturating so a garbage timestamp can't overflow; clamp at 0 so a
    // future timestamp becomes a zero age rather than going negative.
    const age: u64 = @intCast(@max(0, now -| timestamp));
    if (age == 0) return "now";

    // Round down to the largest unit that fits, so Duration.format emits
    // only that unit (e.g. 19d -> 2w, 90m -> 1h).
    const units = [_]u64{
        365 * std.time.s_per_day, // y
        std.time.s_per_week, // w
        std.time.s_per_day, // d
        std.time.s_per_hour, // h
        std.time.s_per_min, // m
        1, // s
    };
    const unit = for (units) |u| {
        if (age >= u) break u;
    } else 1;

    // Cap the age so `age * ns_per_s` can't overflow u64 (a garbage, e.g.
    // hugely negative, timestamp otherwise yields an age near i64-max).
    const max_age = std.math.maxInt(u64) / std.time.ns_per_s;
    const rounded = @min(age, max_age) / unit * unit;
    const d: Duration = .{ .duration = rounded * std.time.ns_per_s };
    return std.fmt.bufPrint(buf, "{f} ago", .{d}) catch unreachable;
}

test relativeAge {
    const testing = std.testing;
    var buf: [32]u8 = undefined;
    const now: i64 = 2_000_000_000; // fixed reference
    const min = std.time.s_per_min;
    const hour = std.time.s_per_hour;
    const day = std.time.s_per_day;

    // Out-of-range timestamps don't crash: a huge future one saturates to
    // a non-positive age ("now"); a negative one is a large but real age.
    try testing.expectEqualStrings("now", relativeAge(&buf, now, std.math.maxInt(i64)));
    try testing.expectEqualStrings("63y ago", relativeAge(&buf, now, -100));

    // A huge age (garbage timestamp) saturates the ns conversion instead of
    // overflowing; it must not crash and must fit the buffer.
    try testing.expect(std.mem.endsWith(u8, relativeAge(&buf, std.math.maxInt(i64), 0), " ago"));

    // Future timestamp (clock skew) and same-instant read "now".
    try testing.expectEqualStrings("now", relativeAge(&buf, now, now + 100));
    try testing.expectEqualStrings("now", relativeAge(&buf, now, now));

    // Only the single largest unit is kept (smaller units rounded away).
    try testing.expectEqualStrings("30s ago", relativeAge(&buf, now, now - 30));
    try testing.expectEqualStrings("1m ago", relativeAge(&buf, now, now - min));
    try testing.expectEqualStrings("1m ago", relativeAge(&buf, now, now - 90)); // 90s -> 1m
    try testing.expectEqualStrings("1h ago", relativeAge(&buf, now, now - hour));
    try testing.expectEqualStrings("1h ago", relativeAge(&buf, now, now - (hour + 30 * min))); // 1h30m -> 1h
    try testing.expectEqualStrings("1d ago", relativeAge(&buf, now, now - day));
    try testing.expectEqualStrings("2w ago", relativeAge(&buf, now, now - 19 * day)); // 19d -> 2w
}

test {
    _ = DiskCache;
    _ = Entry;
}

test "runInner rejects multiple actions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var stdout: std.Io.Writer.Allocating = .init(alloc);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(alloc);
    defer stderr.deinit();

    // The check runs before any cache access, so it never touches disk.
    const code = try runInner(alloc, .{
        .add = "example.com",
        .remove = "other.com",
    }, null, &stdout.writer, &stderr.writer);

    try testing.expectEqual(@as(u8, 2), code);
    try testing.expectEqualStrings("", stdout.written());
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "only one") != null);

    // A positional query is itself an action: query + a flag conflicts.
    stderr.clearRetainingCapacity();
    const code2 = try runInner(alloc, .{
        .clear = true,
    }, "example.com", &stdout.writer, &stderr.writer);
    try testing.expectEqual(@as(u8, 2), code2);
    try testing.expect(std.mem.indexOf(u8, stderr.written(), "only one") != null);
}
