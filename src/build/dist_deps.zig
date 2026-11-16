//! The build tool behind `zig build dist-deps`. It makes the libghostty-vt
//! dependency tarball, such as `libghostty-vt-0.1.0-deps.tar.gz`, which is
//! published next to the source tarball of the same version.
//!
//! # What the tarball is for
//!
//! Building libghostty-vt needs a few Zig packages. Normally Zig downloads
//! them during the build, but many packaging environments have no network
//! access. The dependency tarball contains those packages, already
//! unpacked, so a packager only needs to unpack it and pass the directory to
//! `zig build --system`:
//!
//!   tar -xzf libghostty-vt-0.1.0.tar.gz
//!   tar -xzf libghostty-vt-0.1.0-deps.tar.gz
//!   cd libghostty-vt-0.1.0
//!   zig build --system ../libghostty-vt-0.1.0-deps
//!
//! # Layout
//!
//! The tarball unpacks into a single directory. Each child of that directory
//! is one package, named by its Zig package hash. This is the same layout
//! Zig uses for its own package cache (`<cache>/p/`), which is what
//! `--system` expects:
//!
//!   libghostty-vt-0.1.0-deps/
//!     uucode-0.2.0-ZZjBPm6FVgBcY-79AHV8ckQj86z0JwOyVyj89VeZrEiv/
//!     N-V-__8AAGmZhABbsPJLfbqrh6JTHsXhY6qCaLAQyx25e0XE/
//!     ...
//!
//! The packages are exactly the ones `deps/libghostty-vt.txt` lists. The
//! tool fails if it ends up with any package that the list doesn't name, or
//! if a listed package is missing.
//!
//! # How it works
//!
//! 1. Runs `nix/build-support/fetch-zig-cache.sh` with the list, using an
//!    empty directory as the Zig cache. The script downloads and unpacks
//!    every listed package into `<cache>/p/<hash>/`.
//! 2. Checks the unpacked package directories against the list.
//! 3. Writes those directories into the tarball. The fetch also leaves a
//!    `<hash>.tar.gz` archive next to each package, plus Zig's own cache
//!    directories. None of these go into the tarball.
//!
//! The result is reproducible. Entries are sorted by name, and every entry
//! has a modification time of 0 and owner 0. Modes are 0o755 for
//! directories and executable files and 0o644 for everything else. So the
//! same list always gives the same bytes, whether it is built from a git
//! checkout or from the source tarball, and on any machine.
//!
//! # Usage
//!
//! You don't normally run this tool yourself. `zig build dist-deps` runs it
//! with these arguments:
//!
//!   dist_deps <zig_exe> <fetch_script> <list> <packages.json> <prefix> \
//!     <work_dir> <output.tar.gz>
//!
//!   zig_exe        The Zig to fetch with, put first on PATH for the script.
//!   fetch_script   nix/build-support/fetch-zig-cache.sh.
//!   list           The package URLs, deps/libghostty-vt.txt.
//!   packages.json  Maps each package hash to its URL, deps/packages.json.
//!   prefix         The directory the tarball unpacks to, such as
//!                  libghostty-vt-0.1.0-deps.
//!   work_dir       A directory to fetch into. The tool empties it before
//!                  fetching and again once the tarball is written.
//!   output.tar.gz  Where to write the tarball.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub fn main(init: std.process.Init) !void {
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 8) {
        std.log.err(
            "usage: dist_deps <zig_exe> <fetch_script> <list> <packages.json> " ++
                "<prefix> <work_dir> <output.tar.gz>",
            .{},
        );
        std.process.exit(1);
    }
    const zig_exe = args[1];
    const fetch_script = args[2];
    const list_path = args[3];
    const json_path = args[4];
    const prefix = args[5];
    const work_dir = args[6];
    const output_path = args[7];

    const cwd = Io.Dir.cwd();
    const expected = try expectedHashes(alloc, io, list_path, json_path);

    // Start from an empty cache, even if an earlier run failed partway and
    // left packages behind.
    try cwd.deleteTree(io, work_dir);
    try cwd.createDirPath(io, work_dir);

    // Fetch the packages. The script runs whatever `zig` is on PATH, so
    // put the Zig that runs this build first. That way the packages are
    // unpacked by the same Zig version that will build with them.
    {
        var env = try init.environ_map.clone(alloc);
        try env.put("ZIG_GLOBAL_CACHE_DIR", work_dir);
        try env.put("ZIG_ZON_JSON", json_path);
        const zig_dir = std.fs.path.dirname(zig_exe) orelse ".";
        try env.put("PATH", if (env.get("PATH")) |path|
            try std.fmt.allocPrint(alloc, "{s}{c}{s}", .{
                zig_dir,
                std.fs.path.delimiter,
                path,
            })
        else
            zig_dir);

        var child = try std.process.spawn(io, .{
            .argv = &.{ "sh", fetch_script, list_path },
            .environ_map = &env,
            .stdin = .ignore,
            .stdout = .inherit,
            .stderr = .inherit,
        });
        const term = try child.wait(io);
        if (!term.success()) {
            std.log.err("{s} failed: {any}", .{ fetch_script, term });
            std.process.exit(1);
        }
    }

    const pkg_path = try std.fs.path.join(alloc, &.{ work_dir, "p" });
    var pkg_dir = try cwd.openDir(io, pkg_path, .{ .iterate = true });
    defer pkg_dir.close(io);

    // Only directories are packages. The other entries in p/, such as the
    // <hash>.tar.gz archives, are skipped. The package directories must
    // match the list exactly, with nothing missing and nothing extra.
    const packages = try sortedEntries(alloc, io, pkg_dir, .directory);
    {
        var ok = packages.len == expected.count();
        for (packages) |name| {
            if (!expected.contains(name)) {
                std.log.err("{s} is not a package hash in {s}", .{ name, json_path });
                ok = false;
            }
        }
        var it = expected.keyIterator();
        while (it.next()) |hash| {
            for (packages) |name| {
                if (std.mem.eql(u8, name, hash.*)) break;
            } else {
                std.log.err("{s} was not fetched", .{hash.*});
                ok = false;
            }
        }
        if (!ok) std.process.exit(1);
    }

    // Write the tarball: the prefix directory first, then each package
    // directory and everything inside it, all in name order.
    {
        const file = try cwd.createFile(io, output_path, .{});
        defer file.close(io);
        var file_buf: [64 * 1024]u8 = undefined;
        var file_writer = file.writer(io, &file_buf);

        var window: [std.compress.flate.max_window_len]u8 = undefined;
        var gzip = try std.compress.flate.Compress.init(
            &file_writer.interface,
            &window,
            .gzip,
            .best,
        );

        var tar: std.tar.Writer = .{ .underlying_writer = &gzip.writer };
        try writeDir(alloc, &tar, prefix);
        for (packages) |name| {
            const sub = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, name });
            var dir = try pkg_dir.openDir(io, name, .{ .iterate = true });
            defer dir.close(io);
            try writeDir(alloc, &tar, sub);
            try writeTree(alloc, io, &tar, dir, sub);
        }
        try tar.finishPedantically();

        try gzip.finish();
        try file_writer.interface.flush();
    }

    // The packages are in the tarball now. Delete the unpacked copy so it
    // doesn't take up space in the build cache.
    try cwd.deleteTree(io, work_dir);
    try cwd.createDirPath(io, work_dir);
}

/// Returns the package hash of every URL in the list at `list_path`. These
/// are the directory names the fetch should produce.
///
/// The hashes come from `json_path` (deps/packages.json), which has one
/// entry per package, keyed by hash:
///
///   "uucode-0.2.0-ZZjB...": { "name": "uucode", "url": "https://...", ... }
///
/// Blank lines in the list are ignored. A URL that isn't in the JSON file
/// is an error, since its hash is unknown.
fn expectedHashes(
    alloc: Allocator,
    io: Io,
    list_path: []const u8,
    json_path: []const u8,
) !std.StringHashMapUnmanaged(void) {
    const cwd = Io.Dir.cwd();
    const json_text = try cwd.readFileAlloc(io, json_path, alloc, .unlimited);
    const json = try std.json.parseFromSliceLeaky(
        std.json.ArrayHashMap(struct { url: []const u8 }),
        alloc,
        json_text,
        .{ .ignore_unknown_fields = true },
    );

    var result: std.StringHashMapUnmanaged(void) = .empty;
    const list = try cwd.readFileAlloc(io, list_path, alloc, .unlimited);
    var lines = std.mem.tokenizeAny(u8, list, "\r\n");
    while (lines.next()) |line| {
        const url = std.mem.trim(u8, line, " \t");
        if (url.len == 0) continue;
        var it = json.map.iterator();
        const hash = while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.url, url)) break entry.key_ptr.*;
        } else {
            std.log.err("no hash for {s} in {s}", .{ url, json_path });
            std.process.exit(1);
        };
        try result.put(alloc, hash, {});
    }
    return result;
}

/// Writes everything under `dir` to `tar`, in name order, with each path
/// starting with `prefix`. For example, with the prefix
/// `libghostty-vt-0.1.0-deps/uucode-...`, the file `build.zig` in `dir` is
/// written as `libghostty-vt-0.1.0-deps/uucode-.../build.zig`.
///
/// Directories, regular files and symbolic links are supported. Any other
/// kind of file is an error.
fn writeTree(
    alloc: Allocator,
    io: Io,
    tar: *std.tar.Writer,
    dir: Io.Dir,
    prefix: []const u8,
) !void {
    const names = try sortedEntries(alloc, io, dir, null);
    for (names) |name| {
        const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, name });
        const stat = try dir.statFile(io, name, .{ .follow_symlinks = false });
        switch (stat.kind) {
            .directory => {
                try writeDir(alloc, tar, path);
                var sub = try dir.openDir(io, name, .{ .iterate = true });
                defer sub.close(io);
                try writeTree(alloc, io, tar, sub, path);
            },
            .file => {
                // Zig's package hash includes whether each file is
                // executable, so the bit must survive the round trip.
                const exec = stat.permissions.toMode() & 0o111 != 0;
                const file = try dir.openFile(io, name, .{});
                defer file.close(io);
                var buf: [64 * 1024]u8 = undefined;
                var reader = file.reader(io, &buf);
                try tar.writeFileStream(path, stat.size, &reader.interface, .{
                    .mode = if (exec) 0o755 else 0o644,
                });
            },
            .sym_link => {
                var buf: [std.fs.max_path_bytes]u8 = undefined;
                const len = try dir.readLink(io, name, &buf);
                try tar.writeLink(path, buf[0..len], .{ .mode = 0o777 });
            },
            else => {
                std.log.err("{s}: unsupported file type {t}", .{ path, stat.kind });
                std.process.exit(1);
            },
        }
    }
}

/// Returns the names of the entries in `dir`, sorted byte by byte so the
/// order is the same on every machine. If `kind` is set, only entries of
/// that kind are returned.
fn sortedEntries(
    alloc: Allocator,
    io: Io,
    dir: Io.Dir,
    kind: ?Io.File.Kind,
) ![]const []const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (kind) |k| if (entry.kind != k) continue;
        try names.append(alloc, try alloc.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);
    return names.items;
}

/// Writes a directory entry for `path`. Tar tools such as GNU tar and
/// `git archive` end directory names with a slash, such as `foo/`, but
/// std.tar.Writer doesn't add one. This adds it so the tarball follows the
/// usual convention.
fn writeDir(alloc: Allocator, tar: *std.tar.Writer, path: []const u8) !void {
    const name = try std.fmt.allocPrint(alloc, "{s}/", .{path});
    try tar.writeDir(name, .{ .mode = 0o755 });
}
