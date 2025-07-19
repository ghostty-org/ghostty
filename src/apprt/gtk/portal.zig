const std = @import("std");

const gio = @import("gio");

const Allocator = std.mem.Allocator;

pub const OpenURI = @import("portal/OpenURI.zig");

/// Generate a token suitable for use in requests to the XDG Desktop Portal
pub fn generateToken() usize {
    return std.crypto.random.int(usize);
}

/// Get the XDG portal request path for the current Ghostty instance.
///
/// If this sounds like nonsense, see `request` for an explanation as to
/// why we need to do this.
pub fn getRequestPath(alloc: Allocator, dbus: *gio.DBusConnection, token: usize) (Allocator.Error || std.fmt.BufPrintError || error{NoDBusUniqueName})![:0]const u8 {
    // See https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.Request.html
    // for the syntax XDG portals expect.

    var token_buf: [16]u8 = undefined;
    const token_string = try std.fmt.bufPrint(&token_buf, "{x:0>16}", .{token});

    // Get the unique name from D-Bus and strip the leading `:`
    const unique_name = try alloc.dupe(u8, std.mem.span(
        dbus.getUniqueName() orelse {
            return error.NoDBusUniqueName;
        },
    )[1..]);
    defer alloc.free(unique_name);

    // Sanitize the unique name by replacing every `.` with `_`. In effect, this
    // will turn a unique name like `1.192` into `1_192`.
    std.mem.replaceScalar(u8, unique_name, '.', '_');

    const object_path = try std.mem.joinZ(
        alloc,
        "/",
        &.{
            "/org/freedesktop/portal/desktop/request",
            unique_name, // Remove leading `:`
            token_string,
        },
    );

    return object_path;
}

/// Try and parse the token out of a request path.
pub fn parseRequestPath(request_path: []const u8) ?usize {
    const index = std.mem.lastIndexOfScalar(u8, request_path, '/') orelse return null;
    const token = request_path[index + 1 ..];
    return std.fmt.parseUnsigned(usize, token, 16) catch return null;
}

test "parseRequestPath" {
    const testing = std.testing;

    try testing.expectEqual(0x75af01a79c6fea34, parseRequestPath("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fea34").?);
    try testing.expectEqual(null, parseRequestPath("/org/freedesktop/portal/desktop/request/1_42/75af01a79c6fGa34"));
    try testing.expectEqual(null, parseRequestPath("75af01a79c6fea34"));
}
