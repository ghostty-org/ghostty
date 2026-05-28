const std = @import("std");

const gio = @import("gio");

const Allocator = std.mem.Allocator;

pub const OpenURI = @import("portal/OpenURI.zig");
pub const token_hex_len = @sizeOf(usize) * 2;
pub const TokenBuffer = [token_hex_len + 1]u8;
const token_format = std.fmt.comptimePrint("{{x:0>{}}}", .{token_hex_len});

/// Generate a token suitable for use in requests to the XDG Desktop Portal
pub fn generateToken() usize {
    return std.crypto.random.int(usize);
}

/// Format a request token consistently for use in portal object paths and payloads.
pub fn formatToken(buf: *TokenBuffer, token: usize) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, token_format, .{token}) catch unreachable;
}

/// Get the XDG portal request path for the current Ghostty instance.
///
/// See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html
/// for the protocol of the Request interface.
pub fn getRequestPath(alloc: Allocator, dbus: *gio.DBusConnection, token: usize) (Allocator.Error || error{NoDBusUniqueName})![:0]const u8 {
    // Get the unique name from D-Bus and strip the leading `:`
    const unique_name = std.mem.span(
        dbus.getUniqueName() orelse {
            return error.NoDBusUniqueName;
        },
    )[1..];

    return buildRequestPath(alloc, unique_name, token);
}

/// Build the XDG portal request path for given unique name and token.
fn buildRequestPath(alloc: Allocator, unique_name: []const u8, token: usize) Allocator.Error![:0]const u8 {
    var token_buf: TokenBuffer = undefined;
    const token_string = formatToken(&token_buf, token);

    const object_path = try std.mem.joinZ(
        alloc,
        "/",
        &.{
            "/org/freedesktop/portal/desktop/request",
            unique_name,
            token_string,
        },
    );

    // Sanitize the unique name by replacing every `.` with `_`. In effect, this
    // will turn a unique name like `1.192` into `1_192`.
    // This sounds arbitrary, but it's part of the Request protocol.
    _ = std.mem.replaceScalar(u8, object_path, '.', '_');

    return object_path;
}

/// Try and parse the token out of a request path.
pub fn parseRequestPathToken(request_path: []const u8) ?usize {
    const index = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return null;
    const token = request_path[index + 1 ..];
    return std.fmt.parseUnsigned(usize, token, 16) catch return null;
}

test "formatToken pads to fixed width" {
    const testing = std.testing;

    var token_buf: TokenBuffer = undefined;
    const token = formatToken(&token_buf, 0x42);

    try testing.expectEqual(@as(usize, token_hex_len), token.len);
    try testing.expectEqualStrings("0000000000000042", token);
}

test "buildRequestPath" {
    const testing = std.testing;

    const path = try buildRequestPath(testing.allocator, "1.42", 0x75af01a79c6fea34);
    try testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34",
        path,
    );
    testing.allocator.free(path);
}

test "buildRequestPath pads token" {
    const testing = std.testing;
    const path = try buildRequestPath(testing.allocator, "1.42", 0x42);

    try testing.expectEqualStrings(
        "/org/freedesktop/portal/desktop/request/1_42/0000000000000042",
        path,
    );
    testing.allocator.free(path);
}

test "parseRequestPathToken" {
    const testing = std.testing;

    try testing.expectEqual(0x75af01a79c6fea34, parseRequestPathToken("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34").?);
    try testing.expectEqual(null, parseRequestPathToken("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fGa34"));
    try testing.expectEqual(null, parseRequestPathToken("75af01a79c6fea34"));
}
