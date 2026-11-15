//! Checks that the files that repeat the library version agree with the
//! version the library is built with (`lib_version` in build.zig, a vt-
//! tag, a LIB_VERSION file, or `-Dlib-version-string`). Those files are
//! include/ghostty/vt/version.h, src/terminal/c/ghostty-vt.map and
//! nix/libghostty-vt.nix.
//!
//! This is the root of its own test binary, not part of the libghostty-vt
//! module. build.zig copies those files next to this one so they can be
//! embedded, and passes the library version as `lib_version`.
//!
//! The header is read as text, the same way build systems such as CMake
//! read it, so this also keeps each define on its own simple line.

const std = @import("std");
const lib_version: std.SemanticVersion = @import("lib_version").lib_version;

const header = @embedFile("version.h");
const map = @embedFile("ghostty-vt.map");
const nix = @embedFile("libghostty-vt.nix");

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
    // build's pre-release and build metadata (1.0.0-dev+abc1234) differ
    // per build, and a tagged build of the same commit drops them.
    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "\"{d}.{d}.{d}\"",
        .{ lib_version.major, lib_version.minor, lib_version.patch },
    );
    try testing.expectEqualStrings(expected, try define("GHOSTTY_VT_VERSION"));
}

test "ghostty-vt.map has a node for lib_version and each earlier minor" {
    var minor: usize = 0;
    while (minor <= lib_version.minor) : (minor += 1) {
        var name_buf: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buf,
            "GHOSTTY_VT_{d}.{d}",
            .{ lib_version.major, minor },
        );

        // A node starts in the first column. This skips the worked example
        // in the map's comment, which would otherwise count as a node, and
        // the "} GHOSTTY_VT_1.0;" that chains one node to the previous one.
        var found = false;
        var lines = std.mem.splitScalar(u8, map, '\n');
        while (lines.next()) |line| {
            if (!std.mem.startsWith(u8, line, "GHOSTTY_VT_")) continue;
            var tokens = std.mem.tokenizeAny(u8, line, " \t\r");
            if (!std.mem.eql(u8, tokens.next().?, name)) continue;
            const brace = tokens.next() orelse continue;
            if (std.mem.eql(u8, brace, "{")) found = true;
        }

        if (!found) {
            std.debug.print("ghostty-vt.map has no node {s}\n", .{name});
            return error.MissingNode;
        }
    }
}

test "nix package version matches lib_version" {
    const testing = std.testing;

    // Only the release number has to match. The nix string keeps its own
    // suffix, and a tagged build of the same commit has none.
    const key = "version = \"";
    const start = std.mem.indexOf(u8, nix, key) orelse return error.MissingVersion;
    const rest = nix[start + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, "-+\"") orelse return error.MissingVersion;

    var expected_buf: [128]u8 = undefined;
    const expected = try std.fmt.bufPrint(
        &expected_buf,
        "{d}.{d}.{d}",
        .{ lib_version.major, lib_version.minor, lib_version.patch },
    );
    try testing.expectEqualStrings(expected, rest[0..end]);
}
