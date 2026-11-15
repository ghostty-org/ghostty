//! Finds where a package's files will live once it is installed, so that
//! generated files such as pkg-config `.pc` files and CMake package
//! configs can record those locations.
//!
//! This is harder than it sounds because of staged installs. Packagers
//! usually install into a temporary staging directory named by the
//! `DESTDIR` environment variable, then copy that tree into the real
//! filesystem later. For example:
//!
//!     DESTDIR=/stage zig build --prefix /usr --prefix-lib-dir lib64
//!
//! writes the library to `/stage/usr/lib64`, but the installed `.pc` file
//! must say `prefix=/usr` and `libdir=${prefix}/lib64`, because that is
//! where the library will be when someone uses it.
//!
//! A Zig build script can't get those final paths directly. Zig only
//! exposes the directories it actually writes to, and when `DESTDIR` is
//! set those already include it. Zig picks them like this:
//!
//!   - The prefix is `DESTDIR` joined with `--prefix` (or `/usr` if
//!     `--prefix` isn't given) when `DESTDIR` is set. Otherwise it is
//!     `--prefix`, or `zig-out` in the build root if that isn't given
//!     either.
//!   - The lib directory is `--prefix-lib-dir` if it is absolute, or that
//!     directory under the prefix if it is relative, or `<prefix>/lib` if
//!     the option isn't given. The bin (`--prefix-exe-dir`) and include
//!     (`--prefix-include-dir`) directories work the same way.
//!
//! Note that an absolute directory option is used exactly as given. Zig
//! never adds `DESTDIR` to it.
//!
//! This file undoes that join. A generator gets the directories Zig
//! writes to, reads `DESTDIR` itself, and removes it from the front of
//! every directory that is inside it.
//!
//! ## Usage
//!
//! The build script and the generator each call one function, and the two
//! are made to work together. The directories are always the last four
//! arguments, so add the generator's own arguments first:
//!
//! ```zig
//! // build.zig
//! const run = b.addRunArtifact(generator);
//! run.addArg("--some-option");
//! InstallDirs.addRunArgs(run);
//! const output = run.captureStdOut(.{});
//!
//! // The generator, which imports this file as the "InstallDirs" module.
//! pub fn main(init: std.process.Init) !void {
//!     const alloc = init.arena.allocator();
//!     const args = try init.minimal.args.toSlice(alloc);
//!     const dirs_start = args.len - InstallDirs.run_arg_count;
//!     const own_args = args[1..dirs_start]; // { "--some-option" }
//!     const dirs: InstallDirs = try .fromRunArgs(
//!         alloc,
//!         init.io,
//!         init.environ_map,
//!         args[dirs_start..],
//!     );
//!     // For the install above, dirs.prefix is "/usr" and dirs.lib is
//!     // "/usr/lib64".
//! }
//! ```
//!
//! `addRunArgs` also sets up the step so that the generator always sees
//! the current `DESTDIR`. Its documentation explains why that needs care.
const InstallDirs = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const path = std.fs.path;

/// Where the package's top-level directory will be once installed, for
/// example "/usr".
///
/// This and the other fields are absolute paths in a clean form, with no
/// "." or ".." parts and no separator at the end.
prefix: []const u8,

/// Where executables (and, on Windows, DLLs) will be, for example
/// "/usr/bin".
bin: []const u8,

/// Where libraries will be, for example "/usr/lib64". It is usually
/// inside `prefix`, but doesn't have to be.
lib: []const u8,

/// Where headers will be, for example "/usr/include".
include: []const u8,

/// The directories Zig writes the install to, as absolute paths. When
/// `DESTDIR` is set, these include it.
pub const Staged = struct {
    prefix: []const u8,
    bin: []const u8,
    lib: []const u8,
    include: []const u8,
};

/// The number of arguments `addRunArgs` adds and `fromRunArgs` reads.
pub const run_arg_count = 4;

/// Adds the install directories to `run` as its next four arguments, in
/// the order prefix, bin, lib, include. Call it after adding the tool's
/// other arguments, so these are the last four. The tool reads them back
/// with `fromRunArgs`.
///
/// This also marks the step as having side effects, so that it runs on
/// every build. The tool reads `DESTDIR` from its environment, which the
/// build cache doesn't know about, and two different installs can pass
/// the same arguments. For example, `DESTDIR=/a --prefix /usr` and
/// `--prefix /a/usr` both pass `/a/usr`, but only the first one should
/// record `/usr`. Running the tool every time avoids reusing the wrong
/// output.
///
/// Don't call `setEnvironmentVariable` (or anything else that sets the
/// environment) on `run`. In Zig 0.17, doing that makes the step run with
/// a copy of the environment taken when the build was configured. Zig can
/// reuse that configuration on later builds, so the tool could see an
/// old `DESTDIR`. Pass options to the tool as arguments instead.
pub fn addRunArgs(run: *std.Build.Step.Run) void {
    const b = run.step.owner;
    run.has_side_effects = true;
    inline for (.{ .install_prefix, .install_bin, .install_lib, .install_include }) |base| {
        run.addDirectoryArg2(b.graph.path(base, ""), .{
            .make_absolute = true,
        });
    }
}

/// Reads the arguments `addRunArgs` added, and the `DESTDIR` variable
/// from `environ_map`, and returns where the directories will be once
/// installed. `args` must be exactly those `run_arg_count` arguments,
/// usually the last ones the tool was given.
///
/// A relative `DESTDIR` is taken relative to the current directory, the
/// same way Zig reads it.
pub fn fromRunArgs(
    alloc: Allocator,
    io: std.Io,
    environ_map: *const std.process.Environ.Map,
    args: []const []const u8,
) !InstallDirs {
    if (args.len != run_arg_count) return error.InvalidArgs;
    return try .init(
        alloc,
        try std.process.currentPathAlloc(io, alloc),
        environ_map.get("DESTDIR"),
        .{
            .prefix = args[0],
            .bin = args[1],
            .lib = args[2],
            .include = args[3],
        },
    );
}

/// Returns where the `staged` directories will be once installed.
/// `fromRunArgs` calls this. Use it directly when the inputs come from
/// somewhere else, such as a test.
///
/// `destdir` is the value of `DESTDIR`, or null if it isn't set. An empty
/// value or "/" means the install isn't staged. `cwd` is the absolute
/// path that a relative `destdir` is relative to.
///
/// Every staged directory inside `destdir` has `destdir` removed from the
/// front. A directory outside it, such as an absolute `--prefix-lib-dir`,
/// is returned as it is. For example, with `destdir` "/stage":
///
///     staged prefix "/stage/usr"        ->  prefix "/usr"
///     staged lib    "/stage/usr/lib64"  ->  lib    "/usr/lib64"
///     staged lib    "/opt/lib"          ->  lib    "/opt/lib"
///
/// Returns `error.PrefixNotInDestdir` if `destdir` is set but the prefix
/// isn't inside it. Zig always puts it there, so this means the inputs
/// didn't come from Zig.
pub fn init(
    alloc: Allocator,
    cwd: []const u8,
    destdir: ?[]const u8,
    staged: Staged,
) error{ OutOfMemory, PrefixNotInDestdir }!InstallDirs {
    const root: ?[]const u8 = if (destdir) |d| root: {
        if (d.len == 0) break :root null;
        const resolved = try path.resolve(alloc, &.{ cwd, d });
        if (isRoot(resolved)) break :root null;
        break :root resolved;
    } else null;

    const prefix = try path.resolve(alloc, &.{staged.prefix});
    if (root) |r| if (under(r, prefix) == null) return error.PrefixNotInDestdir;

    return .{
        .prefix = try unstage(alloc, root, prefix),
        .bin = try unstage(alloc, root, try path.resolve(alloc, &.{staged.bin})),
        .lib = try unstage(alloc, root, try path.resolve(alloc, &.{staged.lib})),
        .include = try unstage(alloc, root, try path.resolve(alloc, &.{staged.include})),
    };
}

/// Returns the part of `dir` after `prefix` if `dir` is inside `prefix`,
/// an empty string if `dir` is `prefix` itself, or null if `dir` is
/// outside it. `dir` should be one of the fields. The result uses the
/// platform's path separator.
///
///     prefix "/usr", dir "/usr/lib64"  ->  "lib64"
///     prefix "/usr", dir "/usr"        ->  ""
///     prefix "/usr", dir "/opt/lib"    ->  null
///
/// This suits formats that write paths inside the prefix differently,
/// such as `${prefix}/lib64` in a pkg-config file.
pub fn underPrefix(self: *const InstallDirs, dir: []const u8) ?[]const u8 {
    return under(self.prefix, dir);
}

/// Returns the path that leads from the directory `from` to `to`, using
/// `..` to go up when needed, or "." if they are the same directory.
/// Both must be absolute and in the same clean form as the fields.
///
///     from "/usr",                    to "/usr/lib64"  ->  "lib64"
///     from "/usr/lib64/cmake/foo",    to "/usr"        ->  "../../.."
///     from "/usr",                    to "/opt/lib"    ->  "../opt/lib"
///
/// The result always uses `/` as the separator, which CMake accepts on
/// every platform.
pub fn relative(
    alloc: Allocator,
    from: []const u8,
    to: []const u8,
) Allocator.Error![]const u8 {
    // Both paths are absolute, so the cwd and environment arguments are
    // never used.
    const rel = try path.relative(alloc, from, null, from, to);
    if (rel.len == 0) return ".";
    if (path.sep != '/') std.mem.replaceScalar(u8, rel, path.sep, '/');
    return rel;
}

/// Removes `root` from the front of `dir`, keeping the separator that
/// follows it, so "/stage/usr" becomes "/usr". Returns `dir` unchanged if
/// `root` is null or `dir` isn't inside it.
fn unstage(alloc: Allocator, root: ?[]const u8, dir: []const u8) Allocator.Error![]const u8 {
    const r = root orelse return dir;
    const rest = under(r, dir) orelse return dir;
    if (rest.len == 0) return try alloc.dupe(u8, path.sep_str);
    return try std.mem.concat(alloc, u8, &.{ path.sep_str, rest });
}

/// Returns the part of `dir` after `parent` and the separator between
/// them, an empty string if they are equal, or null if `dir` isn't inside
/// `parent`. Both must be in clean form. Checking for the separator
/// matters: "/stage2" is not inside "/stage".
fn under(parent: []const u8, dir: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, parent, dir)) return "";
    if (!std.mem.startsWith(u8, dir, parent)) return null;
    // A root such as "/" already ends with its separator.
    if (isRoot(parent)) return dir[parent.len..];
    if (!path.isSep(dir[parent.len])) return null;
    return dir[parent.len + 1 ..];
}

/// Returns whether a path in clean form is a filesystem root, such as "/"
/// or "C:\". After cleaning, only a root ends with a separator.
fn isRoot(p: []const u8) bool {
    return p.len > 0 and path.isSep(p[p.len - 1]);
}

test "init" {
    if (path.sep != '/') return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct {
        name: []const u8,
        destdir: ?[]const u8,
        staged: Staged,
        want: Staged,
    }{
        .{
            .name = "default zig-out",
            .destdir = null,
            .staged = .{ .prefix = "/src/zig-out", .bin = "/src/zig-out/bin", .lib = "/src/zig-out/lib", .include = "/src/zig-out/include" },
            .want = .{ .prefix = "/src/zig-out", .bin = "/src/zig-out/bin", .lib = "/src/zig-out/lib", .include = "/src/zig-out/include" },
        },
        .{
            .name = "DESTDIR with --prefix /usr --prefix-lib-dir lib64",
            .destdir = "/stage",
            .staged = .{ .prefix = "/stage/usr", .bin = "/stage/usr/bin", .lib = "/stage/usr/lib64", .include = "/stage/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib64", .include = "/usr/include" },
        },
        .{
            .name = "Zig's join can double the separator",
            .destdir = "/stage/",
            .staged = .{ .prefix = "/stage//usr", .bin = "/stage//usr/bin", .lib = "/stage//usr/lib", .include = "/stage//usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
        },
        .{
            .name = "relative DESTDIR, with the staged paths made absolute",
            .destdir = "../stage",
            .staged = .{ .prefix = "/work/src/../stage/usr", .bin = "/work/src/../stage/usr/bin", .lib = "/work/src/../stage/usr/lib", .include = "/work/src/../stage/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
        },
        .{
            .name = "directory that only starts with the same characters as DESTDIR",
            .destdir = "/st",
            .staged = .{ .prefix = "/st/usr", .bin = "/st/usr/bin", .lib = "/stage/lib", .include = "/st/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/stage/lib", .include = "/usr/include" },
        },
        .{
            .name = "absolute lib dir is not staged",
            .destdir = "/stage",
            .staged = .{ .prefix = "/stage/usr", .bin = "/stage/usr/bin", .lib = "/opt/lib", .include = "/stage/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/opt/lib", .include = "/usr/include" },
        },
        .{
            .name = "relative lib dir outside the prefix",
            .destdir = "/stage",
            .staged = .{ .prefix = "/stage/usr", .bin = "/stage/usr/bin", .lib = "/stage/usr/../lib", .include = "/stage/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/lib", .include = "/usr/include" },
        },
        .{
            .name = "empty DESTDIR is ignored",
            .destdir = "",
            .staged = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
        },
        .{
            .name = "DESTDIR=/ stages nothing",
            .destdir = "/",
            .staged = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
            .want = .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
        },
        .{
            .name = "--prefix / under DESTDIR",
            .destdir = "/stage",
            .staged = .{ .prefix = "/stage", .bin = "/stage/bin", .lib = "/stage/lib", .include = "/stage/include" },
            .want = .{ .prefix = "/", .bin = "/bin", .lib = "/lib", .include = "/include" },
        },
    };

    for (cases) |c| {
        errdefer std.debug.print("case: {s}\n", .{c.name});
        const got: InstallDirs = try .init(alloc, "/work/src", c.destdir, c.staged);
        try std.testing.expectEqualStrings(c.want.prefix, got.prefix);
        try std.testing.expectEqualStrings(c.want.bin, got.bin);
        try std.testing.expectEqualStrings(c.want.lib, got.lib);
        try std.testing.expectEqualStrings(c.want.include, got.include);
    }

    try std.testing.expectError(error.PrefixNotInDestdir, InstallDirs.init(
        alloc,
        "/work/src",
        "/stage",
        .{ .prefix = "/usr", .bin = "/usr/bin", .lib = "/usr/lib", .include = "/usr/include" },
    ));
}

test "underPrefix and relative" {
    if (path.sep != '/') return error.SkipZigTest;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct {
        prefix: []const u8,
        dir: []const u8,
        under: ?[]const u8,
        relative: []const u8,
    }{
        .{ .prefix = "/usr", .dir = "/usr/lib64", .under = "lib64", .relative = "lib64" },
        .{ .prefix = "/usr", .dir = "/usr/lib/x86_64-linux-gnu", .under = "lib/x86_64-linux-gnu", .relative = "lib/x86_64-linux-gnu" },
        .{ .prefix = "/usr", .dir = "/usr", .under = "", .relative = "." },
        .{ .prefix = "/usr", .dir = "/usrlocal/lib", .under = null, .relative = "../usrlocal/lib" },
        .{ .prefix = "/usr", .dir = "/opt/lib", .under = null, .relative = "../opt/lib" },
        .{ .prefix = "/", .dir = "/lib", .under = "lib", .relative = "lib" },
    };

    for (cases) |c| {
        const dirs: InstallDirs = .{ .prefix = c.prefix, .bin = "", .lib = "", .include = "" };
        const got = dirs.underPrefix(c.dir);
        if (c.under) |want| {
            try std.testing.expectEqualStrings(want, got.?);
        } else {
            try std.testing.expectEqual(null, got);
        }
        try std.testing.expectEqualStrings(c.relative, try relative(alloc, c.prefix, c.dir));
    }
}
