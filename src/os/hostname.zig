const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

pub const HostnameParsingError = error{
    NoHostnameInUri,
    NoSpaceLeft,
};

pub const UrlParsingError = std.Uri.ParseError || error{
    HostnameIsNotMacAddress,
    NoSchemeProvided,
};

const mac_address_length = 17;

fn isUriPathSeparator(c: u8) bool {
    return switch (c) {
        '?', '#' => true,
        else => false,
    };
}

fn isValidMacAddress(mac_address: []const u8) bool {
    // A valid mac address has 6 two-character components with 5 colons, e.g. 12:34:56:ab:cd:ef.
    if (mac_address.len != 17) {
        return false;
    }

    for (mac_address, 0..) |c, i| {
        if ((i + 1) % 3 == 0) {
            if (c != ':') {
                return false;
            }
        } else if (!std.mem.containsAtLeastScalar(u8, "0123456789ABCDEFabcdef", 1, c)) {
            return false;
        }
    }

    return true;
}

/// Parses the provided url to a `std.Uri` struct. This is very specific to getting hostname and
/// path information for Ghostty's PWD reporting functionality. Takes into account that on macOS
/// the url passed to this function might have a mac address as its hostname and parses it
/// correctly.
pub fn parseUrl(url: []const u8) UrlParsingError!std.Uri {
    return std.Uri.parse(url) catch |e| {
        // The mac-address-as-hostname issue is specific to macOS so we just return an error if we
        // hit it on other platforms.
        if (comptime builtin.os.tag != .macos) return e;

        // It's possible this is a mac address on macOS where the last 2 characters in the
        // address are non-digits, e.g. 'ff', and thus an invalid port.
        //
        // Example: file://12:34:56:78:90:12/path/to/file
        if (e != error.InvalidPort) return e;

        const url_without_scheme_start = std.mem.indexOf(u8, url, "://") orelse {
            return error.NoSchemeProvided;
        };
        const scheme = url[0..url_without_scheme_start];
        const url_without_scheme = url[url_without_scheme_start + 3 ..];

        // The first '/' after the scheme marks the end of the hostname. If the first '/'
        // following the end of the scheme is not at the right position this is not a
        // valid mac address.
        if (url_without_scheme.len != mac_address_length and
            std.mem.indexOfScalarPos(u8, url_without_scheme, 0, '/') != mac_address_length)
        {
            return error.HostnameIsNotMacAddress;
        }

        // At this point we may have a mac address as the hostname.
        const mac_address = url_without_scheme[0..mac_address_length];

        if (!isValidMacAddress(mac_address)) {
            return error.HostnameIsNotMacAddress;
        }

        var uri_path_end_idx: usize = mac_address_length;
        while (uri_path_end_idx < url_without_scheme.len and
            !isUriPathSeparator(url_without_scheme[uri_path_end_idx]))
        {
            uri_path_end_idx += 1;
        }

        // Same compliance factor as std.Uri.parse(), i.e. not at all compliant with the URI
        // spec.
        return .{
            .scheme = scheme,
            .host = .{ .percent_encoded = mac_address },
            .path = .{
                .percent_encoded = url_without_scheme[mac_address_length..uri_path_end_idx],
            },
        };
    };
}

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

test parseUrl {
    // 1. Typical hostnames.

    var uri = try parseUrl("file://personal.computer/home/test/");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("personal.computer", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);

    uri = try parseUrl("kitty-shell-cwd://personal.computer/home/test/");

    try std.testing.expectEqualStrings("kitty-shell-cwd", uri.scheme);
    try std.testing.expectEqualStrings("personal.computer", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);

    // 2. Hostnames that are mac addresses.

    // Numerical mac addresses.

    uri = try parseUrl("file://12:34:56:78:90:12/home/test/");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("12:34:56:78:90", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == 12);

    uri = try parseUrl("kitty-shell-cwd://12:34:56:78:90:12/home/test/");

    try std.testing.expectEqualStrings("kitty-shell-cwd", uri.scheme);
    try std.testing.expectEqualStrings("12:34:56:78:90", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == 12);

    // Alphabetical mac addresses.

    uri = try parseUrl("file://ab:cd:ef:ab:cd:ef/home/test/");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);

    uri = try parseUrl("kitty-shell-cwd://ab:cd:ef:ab:cd:ef/home/test/");

    try std.testing.expectEqualStrings("kitty-shell-cwd", uri.scheme);
    try std.testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("/home/test/", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);

    // 3. Hostnames that are mac addresses with no path.

    // Numerical mac addresses.

    uri = try parseUrl("file://12:34:56:78:90:12");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("12:34:56:78:90", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("", uri.path.percent_encoded);
    try std.testing.expect(uri.port == 12);

    uri = try parseUrl("kitty-shell-cwd://12:34:56:78:90:12");

    try std.testing.expectEqualStrings("kitty-shell-cwd", uri.scheme);
    try std.testing.expectEqualStrings("12:34:56:78:90", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("", uri.path.percent_encoded);
    try std.testing.expect(uri.port == 12);

    // Alphabetical mac addresses.

    uri = try parseUrl("file://ab:cd:ef:ab:cd:ef");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);

    uri = try parseUrl("kitty-shell-cwd://ab:cd:ef:ab:cd:ef");

    try std.testing.expectEqualStrings("kitty-shell-cwd", uri.scheme);
    try std.testing.expectEqualStrings("ab:cd:ef:ab:cd:ef", uri.host.?.percent_encoded);
    try std.testing.expectEqualStrings("", uri.path.percent_encoded);
    try std.testing.expect(uri.port == null);
}

test "parseUrl succeeds even if path component is missing" {
    const uri = try parseUrl("file://12:34:56:78:90:ab");

    try std.testing.expectEqualStrings("file", uri.scheme);
    try std.testing.expectEqualStrings("12:34:56:78:90:ab", uri.host.?.percent_encoded);
    try std.testing.expect(uri.path.isEmpty());
    try std.testing.expect(uri.port == null);
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

test "bufPrintHostnameFromFileUri succeeds with hostname as mac address with the last component as ascii" {
    const uri = try parseUrl("file://12:34:56:78:90:ab");

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const actual = try bufPrintHostnameFromFileUri(&buf, uri);
    try std.testing.expectEqualStrings("12:34:56:78:90:ab", actual);
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
