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

    const root_path = b.build_root.path orelse ".";

    // Check that we're within a git checkout with a .git folder, if not, bail early.
    const git_path = try std.fs.path.join(b.allocator, &[_][]const u8{ root_path, ".git" });
    std.fs.cwd().access(git_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => return err,
    };

    const branch: []const u8 = b.runAllowFail(
        &[_][]const u8{ "git", "-C", root_path, "rev-parse", "--abbrev-ref", "HEAD" },
        &code,
        .Ignore,
    ) catch |err| switch (err) {
        error.FileNotFound => return error.GitNotFound,
        else => return err,
    };

    const short_hash = short_hash: {
        const output = b.runAllowFail(
            &[_][]const u8{ "git", "-C", root_path, "log", "--pretty=format:%h", "-n", "1" },
            &code,
            .Ignore,
        ) catch |err| switch (err) {
            error.FileNotFound => return error.GitNotFound,
            else => return err,
        };

        break :short_hash std.mem.trimRight(u8, output, "\r\n ");
    };

    const tag = b.runAllowFail(
        &[_][]const u8{ "git", "-C", root_path, "describe", "--exact-match", "--tags" },
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
        root_path,
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
