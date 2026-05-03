const Version = @This();

const std = @import("std");

/// The short hash (7 characters) of the latest commit.
short_hash: []const u8,

/// True if there was a diff at build time.
changes: bool,

/// The tag -- if any -- that this commit is a part of.
tag: ?[]const u8,

/// The branch that was checked out at the time of the build.
branch: []const u8,

/// Initialize the version and detect it from the Git environment. This
/// allocates using the build allocator and doesn't free.
pub fn detect(b: *std.Build) !Version {
    // Execute a bunch of git commands to determine the automatic version.
    var code: u8 = 0;
    const branch: []const u8 = b: {
        const tmp: []u8 = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "rev-parse", "--abbrev-ref", "HEAD" },
            &code,
            .Ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            error.ExitCodeFailure => return error.GitNotRepository,
            else => return err,
        };

        // Replace characters that are not valid in semantic version
        // pre-release identifiers (which only allow [0-9A-Za-z-]).
        // Slashes would also mess up dist tarball paths.
        for (tmp) |*c| {
            if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
        }

        break :b tmp;
    };

    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "-c", "log.showSignature=false", "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .Ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        break :short_hash std.mem.trimRight(u8, output, "\r\n ");
    };

    const tag = b.runAllowFail(
        &[_][]const u8{ "git", "-C", b.build_root.path orelse ".", "describe", "--exact-match", "--tags" },
        &code,
        .Ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => "", // expected
        else => return err,
    };

    _ = b.runAllowFail(&[_][]const u8{
        "git",
        "-C",
        b.build_root.path orelse ".",
        "diff",
        "--quiet",
        "--exit-code",
    }, &code, .Ignore) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        error.ExitCodeFailure => {}, // expected
        else => return err,
    };
    const changes = code != 0;

    return .{
        .short_hash = short_hash,
        .changes = changes,
        .tag = if (tag.len > 0) std.mem.trimRight(u8, tag, "\r\n ") else null,
        .branch = std.mem.trimRight(u8, branch, "\r\n "),
    };
}
