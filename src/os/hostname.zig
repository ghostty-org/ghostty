const std = @import("std");
const posix = std.posix;

pub const HostnameParsingError = error{
    NoHostnameInUri,
    NoSpaceLeft,
};

/// Print the hostname from a file URI into a buffer.
pub fn bufPrintHostnameFromFileUri(
    buf: []u8,
    uri: std.Uri,
) HostnameParsingError![]const u8 {
    // Get the raw string of the URI. Its unclear to me if the various
    // tags of this enum guarantee no percent-encoding so we just
    // check all of it. This isn't a performance critical path.
    const host_component = uri.host orelse return error.NoHostnameInUri;
    const host: []const u8 = switch (host_component) {
        .raw => |v| v,
        .percent_encoded => |v| v,
    };

    // When the "Private Wi-Fi address" setting is toggled on macOS the hostname
    // is set to a random mac address, e.g. '12:34:56:78:90:ab'.
    // The URI will be parsed as if the last set of digits is a port number, so
    // we need to make sure that part is included when it's set.

    // We're only interested in special port handling when the current hostname is a
    // partial MAC address that's potentially missing the last component.
    // If that's not the case we just return the plain URI hostname directly.
    // NOTE: This implementation is not sufficient to verify a valid mac address, but
    //       it's probably sufficient for this specific purpose.
    if (host.len != 14 or std.mem.count(u8, host, ":") != 4) return host;

    // If we don't have a port then we can return the hostname as-is because
    // it's not a partial MAC-address.
    const port = uri.port orelse return host;

    // If the port is not a 1 or 2-digit number we're not looking at a partial
    // MAC-address, and instead just a regular port so we return the plain
    // URI hostname.
    if (port > 99) return host;

    var fbs = std.io.fixedBufferStream(buf);
    try std.fmt.format(
        fbs.writer(),
        // Make sure "port" is always 2 digits, prefixed with a 0 when "port" is a 1-digit number.
        "{s}:{d:0>2}",
        .{ host, port },
    );

    return fbs.getWritten();
}

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

test "bufPrintHostnameFromFileUri succeeds with ascii hostname" {
    const uri = try std.Uri.parse("file://localhost/");

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const actual = try bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectEqualStrings("localhost", actual);
}

test "bufPrintHostnameFromFileUri succeeds with hostname as mac address" {
    const uri = try std.Uri.parse("file://12:34:56:78:90:12");

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const actual = try bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectEqualStrings("12:34:56:78:90:12", actual);
}

test "bufPrintHostnameFromFileUri succeeds with hostname as a mac address and the last section is < 10" {
    const uri = try std.Uri.parse("file://12:34:56:78:90:05");

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const actual = try bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectEqualStrings("12:34:56:78:90:05", actual);
}

test "bufPrintHostnameFromFileUri returns only hostname when there is a port component in the URI" {
    // First: try with a non-2-digit port, to test general port handling.
    const four_port_uri = try std.Uri.parse("file://has-a-port:1234");

    var four_port_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const four_port_actual = try bufPrintHostnameFromFileUri(&four_port_buf, four_port_uri);
    try std.testing.expectEqualStrings("has-a-port", four_port_actual);

    // Second: try with a 2-digit port to test mac-address handling.
    const two_port_uri = try std.Uri.parse("file://has-a-port:12");

    var two_port_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const two_port_actual = try bufPrintHostnameFromFileUri(&two_port_buf, two_port_uri);
    try std.testing.expectEqualStrings("has-a-port", two_port_actual);

    // Third: try with a mac-address that has a port-component added to it to test mac-address handling.
    const mac_with_port_uri = try std.Uri.parse("file://12:34:56:78:90:12:1234");

    var mac_with_port_buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const mac_with_port_actual = try bufPrintHostnameFromFileUri(&mac_with_port_buf, mac_with_port_uri);
    try std.testing.expectEqualStrings("12:34:56:78:90:12", mac_with_port_actual);
}

test "bufPrintHostnameFromFileUri returns NoHostnameInUri error when hostname is missing from uri" {
    const uri = try std.Uri.parse("file:///");

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const actual = bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectError(HostnameParsingError.NoHostnameInUri, actual);
}

test "bufPrintHostnameFromFileUri returns NoSpaceLeft error when provided buffer has insufficient size" {
    const uri = try std.Uri.parse("file://12:34:56:78:90:12/");

    var buf: [5]u8 = undefined;
    const actual = bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectError(HostnameParsingError.NoSpaceLeft, actual);
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
