const Version = @This();

const std = @import("std");

/// The short hash (7 characters) of the latest commit.
short_hash: []const u8,

/// True if there was a diff at build time.
changes: bool,

/// Every tag on the latest commit, such as `tip`, `v1.4.1`, and `vt-0.1.0`.
tags: []const []const u8,

/// The branch that was checked out at the time of the build.
branch: []const u8,

/// Initialize the version and detect it from the Git environment. This
/// allocates using the build allocator and doesn't free.
pub fn detect(b: *std.Build) !Version {
    // Execute a bunch of git commands to determine the automatic version.
    var code: u8 = 0;
    const branch: []const u8 = b: {
        const tmp: []u8 = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.root.subPathOrDot(), "rev-parse", "--abbrev-ref", "HEAD" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.ExitCodeFailure => return error.GitNotRepository,
            else => return err,
        };

        // Trim first so the trailing newline isn't sanitized into a '-'.
        const trimmed = tmp[0..std.mem.trim(u8, tmp, &std.ascii.whitespace).len];

        // Replace characters that are not valid in semantic version
        // pre-release identifiers (which only allow [0-9A-Za-z-]).
        // Slashes would also mess up dist tarball paths.
        for (trimmed) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }

        break :b trimmed;
    };

    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.root.subPathOrDot(), "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        break :short_hash std.mem.trim(u8, output, &std.ascii.whitespace);
    };

    const tags: []const []const u8 = tags: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.root.subPathOrDot(), "tag", "--points-at", "HEAD" },
            &code,
            .ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeAny(u8, output, "\r\n ");
        while (it.next()) |tag| try list.append(b.allocator, tag);
        break :tags list.items;
    };

    _ = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.root.subPathOrDot(),
        "diff",
        "--quiet",
        "--exit-code",
    }, &code, .ignore) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => {}, // expected
        else => return err,
    };
    const changes = code != 0;

    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tags = tags,
        .branch = branch,
    };
}
