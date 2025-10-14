const std = @import("std");
const posix = std.posix;

pub const UrlParsingError = std.Uri.ParseError || error{
    HostnameIsNotMacAddress,
    NoSchemeProvided,
};

pub const LocalHostnameValidationError = error{
    PermissionDenied,
    Unexpected,
};

/// Checks if a hostname is local to the current machine. This matches
/// both "localhost" and the current hostname of the machine (as returned
/// by `gethostname`).
pub fn isLocalHostname(hostname: []const u8) LocalHostnameValidationError!bool {
    // A 'localhost' hostname is always considered local.
    if (std.mem.eql(u8, "localhost", hostname)) return true;

    // If hostname is not "localhost" it must match our hostname.
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const ourHostname = try posix.gethostname(&buf);
    return std.mem.eql(u8, hostname, ourHostname);
}

test "isLocalHostname returns true when provided hostname is localhost" {
    try std.testing.expect(try isLocalHostname("localhost"));
}

test "isLocalHostname returns true when hostname is local" {
    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const localHostname = try posix.gethostname(&buf);
    try std.testing.expect(try isLocalHostname(localHostname));
}

test "isLocalHostname returns false when hostname is not local" {
    try std.testing.expectEqual(
        false,
        try isLocalHostname("not-the-local-hostname"),
    );
}
