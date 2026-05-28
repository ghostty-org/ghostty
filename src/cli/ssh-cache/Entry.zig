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

pub const FormatError = std.Io.Writer.Error;

pub fn format(self: Entry, writer: *std.Io.Writer) FormatError!void {
    try writer.print(
        "{s}|{d}|{s}\n",
        .{ self.hostname, self.timestamp, self.terminfo_version },
    );
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
