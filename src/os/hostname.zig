const std = @import("std");
const posix = std.posix;

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Validates a hostname according to [RFC 1123](https://www.rfc-editor.org/rfc/rfc1123)
///
/// std.net.isValidHostname is (currently) too generous. It considers strings like
/// ".example.com", "exa..mple.com", and "-example.com" to be valid hostnames, which
/// is incorrect.
pub fn isValid(hostname: []const u8) bool {
    if (hostname.len == 0) return false;
    if (hostname[0] == '.') return false;

    // Ignore trailing dot (FQDN). It doesn't count toward our length.
    const end = if (hostname[hostname.len - 1] == '.') end: {
        if (hostname.len == 1) return false;
        break :end hostname.len - 1;
    } else hostname.len;

    if (end > 253) return false;

    // Hostnames are divided into dot-separated "labels", which:
    //
    // - Start with a letter or digit
    // - Can contain letters, digits, or hyphens
    // - Must end with a letter or digit
    // - Have a minimum of 1 character and a maximum of 63
    var label_start: usize = 0;
    var label_len: usize = 0;
    for (hostname[0..end], 0..) |c, i| {
        switch (c) {
            '.' => {
                if (label_len == 0 or label_len > 63) return false;
                if (!std.ascii.isAlphanumeric(hostname[label_start])) return false;
                if (!std.ascii.isAlphanumeric(hostname[i - 1])) return false;

                label_start = i + 1;
                label_len = 0;
            },
            '-' => {
                label_len += 1;
            },
            else => {
                if (!std.ascii.isAlphanumeric(c)) return false;
                label_len += 1;
            },
        }
    }

    // Validate the final label
    if (label_len == 0 or label_len > 63) return false;
    if (!std.ascii.isAlphanumeric(hostname[label_start])) return false;
    if (!std.ascii.isAlphanumeric(hostname[end - 1])) return false;

    return true;
}

test isValid {
    const testing = std.testing;

    // Valid hostnames
    try testing.expect(isValid("example"));
    try testing.expect(isValid("example.com"));
    try testing.expect(isValid("www.example.com"));
    try testing.expect(isValid("sub.domain.example.com"));
    try testing.expect(isValid("example.com."));
    try testing.expect(isValid("host-name.example.com."));
    try testing.expect(isValid("123.example.com."));
    try testing.expect(isValid("a-b.com"));
    try testing.expect(isValid("a.b.c.d.e.f.g"));
    try testing.expect(isValid("127.0.0.1")); // Also a valid hostname
    try testing.expect(isValid("a" ** 63 ++ ".com")); // Label exactly 63 chars (valid)
    try testing.expect(isValid("a." ** 126 ++ "a")); // Total length 253 (valid)

    // Invalid hostnames
    try testing.expect(!isValid(""));
    try testing.expect(!isValid(".example.com"));
    try testing.expect(!isValid("example.com.."));
    try testing.expect(!isValid("host..domain"));
    try testing.expect(!isValid("-hostname"));
    try testing.expect(!isValid("hostname-"));
    try testing.expect(!isValid("a.-.b"));
    try testing.expect(!isValid("host_name.com"));
    try testing.expect(!isValid("."));
    try testing.expect(!isValid(".."));
    try testing.expect(!isValid("a" ** 64 ++ ".com")); // Label length 64 (too long)
    try testing.expect(!isValid("a." ** 126 ++ "ab")); // Total length 254 (too long)
}

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocal(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const ourHostname = try posix.gethostname(&buf);
    return std.mem.eql(u8, hostname, ourHostname);
}

test "isLocal returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocal("localhost"));
}

test "isLocal returns true when hostname is local" {
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const localHostname = try posix.gethostname(&buf);
    try std.testing.expect(try isLocal(localHostname));
}

test "isLocal returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocal("not-the-local-hostname"),
    );
}
