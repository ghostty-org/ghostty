//! Generates a `pkg-config` .pc file for `libghostty-vt`.
//!
//! This is required as of Zig 0.17 since the configurer process that runs
//! `build.zig` build scripts can no longer access the install prefix as a
//! simple string and use it to template files.

const std = @import("std");
const options = @import("options");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = try init.minimal.args.iterateAllocator(init.arena.allocator());
    std.debug.assert(args.skip());
    const prefix = args.next() orelse return error.NoPrefix;

    const is_static = init.environ_map.contains("IS_STATIC");

    const stdout = std.Io.File.stdout();
    var stdout_writer = stdout.writer(io, &.{});

    try stdout_writer.interface.print(
        \\prefix={[prefix]s}
        \\includedir=${{prefix}}/include
        \\libdir=${{prefix}}/lib
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
        .prefix = prefix,
        .name = if (is_static) options.name_static else options.name,
        .description = if (is_static) options.description_static else options.description,
        .version = options.version,
        .libs = if (is_static) options.libs else options.libs_static,
        .libs_private = options.libs_private,
        .reqs_private = options.reqs_private,
    });
    try stdout_writer.interface.flush();
}
