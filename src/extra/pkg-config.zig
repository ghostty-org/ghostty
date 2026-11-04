//! Generates a pkg-config `.pc` file for libghostty-vt (and for the
//! internal libghostty), and writes it to stdout.
//!
//! The build script can't write this file itself. In Zig 0.17 the build
//! script runs before Zig knows the final install directories, so the
//! file is made by this small tool, which runs at build time when they
//! are known.
//!
//! Usage:
//!
//!     pkg-config-generator <shared|static> <prefix> <bindir> <libdir> <includedir>
//!
//! The four directories come from `InstallDirs.addRunArgs`. The other
//! fields (name, version, flags) are compiled in through the `options`
//! module.
//!
//! The file records where the package will be once installed, even for a
//! staged install. For example, after
//!
//!     DESTDIR=/stage zig build -Demit-lib-vt --prefix /usr --prefix-lib-dir lib64
//!
//! the shared file starts with:
//!
//!     prefix=/usr
//!     includedir=${prefix}/include
//!     libdir=${prefix}/lib64

const std = @import("std");
const options = @import("options");
const InstallDirs = @import("InstallDirs");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const alloc = init.arena.allocator();
    const args = try init.minimal.args.toSlice(alloc);
    if (args.len != 2 + InstallDirs.run_arg_count) return error.InvalidArgs;

    const is_static = if (std.mem.eql(u8, args[1], "static"))
        true
    else if (std.mem.eql(u8, args[1], "shared"))
        false
    else
        return error.InvalidArgs;

    const dirs: InstallDirs = try .fromRunArgs(alloc, io, init.environ_map, args[2..]);

    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(io, &.{});

    try stdout_writer.interface.print(
        \\prefix={[prefix]s}
        \\includedir={[includedir]s}
        \\libdir={[libdir]s}
        \\
        \\Name: {[name]s}
        \\URL: https://github.com/ghostty-org/ghostty
        \\Description: {[description]s}
        \\Version: {[version]f}
        \\Cflags: -I${{includedir}}
        \\Libs: {[libs]s}
        \\Libs.private: {[libs_private]s}
        \\Requires.private: {[reqs_private]s}
    , .{
        .prefix = dirs.prefix,
        .includedir = try prefixVar(alloc, &dirs, dirs.include),
        .libdir = try prefixVar(alloc, &dirs, dirs.lib),
        .name = if (is_static) options.name_static else options.name,
        .description = if (is_static) options.description_static else options.description,
        .version = options.version,
        .libs = if (is_static) options.libs_static else options.libs,
        .libs_private = options.libs_private,
        .reqs_private = options.reqs_private,
    });
    try stdout_writer.interface.flush();
}

/// Returns how the file should write `dir`. A directory inside the
/// prefix is written relative to it, as pkg-config files usually do, so
/// "/usr/lib64" becomes "${prefix}/lib64". Any other directory is written
/// as its absolute path.
fn prefixVar(
    alloc: std.mem.Allocator,
    dirs: *const InstallDirs,
    dir: []const u8,
) ![]const u8 {
    const rel = dirs.underPrefix(dir) orelse return dir;
    if (rel.len == 0) return "${prefix}";
    return try std.mem.concat(alloc, u8, &.{ "${prefix}/", rel });
}
