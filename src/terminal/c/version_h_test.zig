//! Checks that include/ghostty/vt/version.h agrees with the version the
//! library is built with (`lib_version` in build.zig, a vt- tag, a
//! LIB_VERSION file, or `-Dlib-version-string`).
//!
//! This is the root of its own test binary, not part of the libghostty-vt
//! module. build.zig copies version.h next to this file so it can be
//! embedded, and passes the library version as `lib_version`.
//!
//! The header is read as text, the same way build systems such as CMake
//! read it, so this also keeps each define on its own simple line.

const std = @import("std");
const lib_version: std.SemanticVersion = @import("lib_version").lib_version;

const header = @embedFile("version.h");

/// Returns the value of `#define name value` in the header.
fn define(name: []const u8) ![]const u8 {
    var it = std.mem.splitScalar(u8, header, '\n');
    while (it.next()) |line| {
        var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
        const directive = tokens.next() orelse continue;
        if (!std.mem.eql(u8, directive, "#define")) continue;
        const key = tokens.next() orelse continue;
        if (!std.mem.eql(u8, key, name)) continue;
        const value = tokens.next() orelse return error.MissingValue;
        if (tokens.next() != null) return error.TrailingTokens;
        return value;
    }

    return error.MissingDefine;
}

fn defineInt(name: []const u8) !usize {
    return try std.fmt.parseInt(usize, try define(name), 10);
}

test "version.h matches lib_version" {
    const testing = std.testing;

    try testing.expectEqual(lib_version.major, try defineInt("GHOSTTY_VT_VERSION_MAJOR"));
    try testing.expectEqual(lib_version.minor, try defineInt("GHOSTTY_VT_VERSION_MINOR"));
    try testing.expectEqual(lib_version.patch, try defineInt("GHOSTTY_VT_VERSION_PATCH"));

    // The header string is only the release number. A development
    // build's pre-release and build metadata (0.1.0-dev+abc1234) differ
    // per build, and a tagged build of the same commit drops them.
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\"{d}.{d}.{d}\"",
        .{ lib_version.major, lib_version.minor, lib_version.patch },
    );
    try testing.expectEqualStrings(expected, try define("GHOSTTY_VT_VERSION"));
}
