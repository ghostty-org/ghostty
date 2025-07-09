/// A single entry within our SSH entry cache. Our SSH entry cache
/// stores which hosts we've sent our terminfo to so that we don't have
/// to send it again. It doesn't store any sensitive information.
const Entry = @This();

const std = @import("std");

hostname: []const u8,
timestamp: i64,
terminfo_version: []const u8,

pub fn parse(line: []const u8) ?Entry {
    const trimmed = std.mem.trim(u8, line, " \t\r\n");
    if (trimmed.len == 0) return null;

    // Parse format: hostname|timestamp|terminfo_version
    var iter = std.mem.tokenizeScalar(u8, trimmed, '|');
    const hostname = iter.next() orelse return null;
    const timestamp_str = iter.next() orelse return null;
    const terminfo_version = iter.next() orelse "xterm-ghostty";
    const timestamp = std.fmt.parseInt(i64, timestamp_str, 10) catch |err| {
        std.log.warn(
            "Invalid timestamp in cache entry: {s} err={}",
            .{ timestamp_str, err },
        );
        return null;
    };

    return .{
        .hostname = hostname,
        .timestamp = timestamp,
        .terminfo_version = terminfo_version,
    };
}

pub fn format(self: Entry, writer: anytype) !void {
    try writer.print(
        "{s}|{d}|{s}\n",
        .{ self.hostname, self.timestamp, self.terminfo_version },
    );
}

pub fn isExpired(self: Entry, expire_days_: ?u32) bool {
    const expire_days = expire_days_ orelse return false;
    const now = std.time.timestamp();
    const age_days = @divTrunc(now -| self.timestamp, std.time.s_per_day);
    return age_days > expire_days;
}

test "cache entry expiration" {
    const testing = std.testing;
    const now = std.time.timestamp();

    const fresh_entry: Entry = .{
        .hostname = "test.com",
        .timestamp = now - std.time.s_per_day, // 1 day old
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(!fresh_entry.isExpired(90));

    const old_entry: Entry = .{
        .hostname = "old.com",
        .timestamp = now - (std.time.s_per_day * 100), // 100 days old
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(old_entry.isExpired(90));

    // Test never-expire case
    try testing.expect(!old_entry.isExpired(null));
}

test "cache entry expiration exact boundary" {
    const testing = std.testing;
    const now = std.time.timestamp();

    // Exactly at expiration boundary
    const boundary_entry: Entry = .{
        .hostname = "example.com",
        .timestamp = now - (std.time.s_per_day * 30),
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(!boundary_entry.isExpired(30));
    try testing.expect(boundary_entry.isExpired(29));
}

test "cache entry expiration large timestamp" {
    const testing = std.testing;
    const now = std.time.timestamp();

    const boundary_entry: Entry = .{
        .hostname = "example.com",
        .timestamp = now + (std.time.s_per_day * 30),
        .terminfo_version = "xterm-ghostty",
    };
    try testing.expect(!boundary_entry.isExpired(30));
}

test "cache entry parsing valid formats" {
    const testing = std.testing;

    const entry = Entry.parse("example.com|1640995200|xterm-ghostty").?;
    try testing.expectEqualStrings("example.com", entry.hostname);
    try testing.expectEqual(@as(i64, 1640995200), entry.timestamp);
    try testing.expectEqualStrings("xterm-ghostty", entry.terminfo_version);

    // Test default terminfo version
    const entry_no_version = Entry.parse("test.com|1640995200").?;
    try testing.expectEqualStrings(
        "xterm-ghostty",
        entry_no_version.terminfo_version,
    );

    // Test complex hostnames
    const complex_entry = Entry.parse("user@server.example.com|1640995200|xterm-ghostty").?;
    try testing.expectEqualStrings(
        "user@server.example.com",
        complex_entry.hostname,
    );
}

test "cache entry parsing invalid formats" {
    const testing = std.testing;

    try testing.expect(Entry.parse("") == null);

    // Invalid format (no pipe)
    try testing.expect(Entry.parse("v1") == null);

    // Missing timestamp
    try testing.expect(Entry.parse("example.com") == null);

    // Invalid timestamp
    try testing.expect(Entry.parse("example.com|invalid") == null);

    // Empty terminfo should default
    try testing.expect(Entry.parse("example.com|1640995200|") != null);
}

test "cache entry parsing malformed data resilience" {
    const testing = std.testing;

    // Extra pipes should not break parsing
    try testing.expect(Entry.parse("host|123|term|extra") != null);

    // Whitespace handling
    try testing.expect(Entry.parse("  host|123|term  ") != null);
    try testing.expect(Entry.parse("\n") == null);
    try testing.expect(Entry.parse("   \t  \n") == null);

    // Extremely large timestamp
    try testing.expect(
        Entry.parse("host|999999999999999999999999999999999999999999999999|xterm-ghostty") == null,
    );
}
