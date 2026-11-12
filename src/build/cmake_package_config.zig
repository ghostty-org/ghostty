//! Generates the CMake package config for libghostty-vt, the file that
//! `find_package(ghostty-vt)` loads, and writes it to stdout.
//!
//! It fills in `dist/cmake/ghostty-vt-config.cmake.in`, the same template
//! the CMake build uses with `configure_package_config_file()`, so both
//! builds install an equivalent config.
//!
//! Usage:
//!
//!     cmake_package_config <template> [NAME=VALUE]... <prefix> <bindir> <libdir> <includedir>
//!
//! The four directories come from `InstallDirs.addRunArgs`. This tool
//! works out where they will be once installed and fills in the values
//! that depend on them:
//!
//!   - `PACKAGE_INIT`: CMake code that finds the install prefix by going
//!     up from the config file's own directory, `<libdir>/cmake/ghostty-vt`.
//!   - `CMAKE_INSTALL_BINDIR`, `CMAKE_INSTALL_LIBDIR` and
//!     `CMAKE_INSTALL_INCLUDEDIR`: each directory relative to the prefix.
//!
//! Each `NAME=VALUE` argument fills in another `@NAME@` in the template,
//! as with `configure_file.zig`.
//!
//! For example, after
//!
//!     DESTDIR=/stage zig build -Demit-lib-vt --prefix /usr --prefix-lib-dir lib64
//!
//! the config is installed as
//! `/stage/usr/lib64/cmake/ghostty-vt/ghostty-vt-config.cmake` and contains:
//!
//!     get_filename_component(PACKAGE_PREFIX_DIR "${CMAKE_CURRENT_LIST_DIR}/../../../" ABSOLUTE)
//!     ...
//!     set(_ghostty_vt_libdir "${PACKAGE_PREFIX_DIR}/lib64")
//!
//! No path in the config is absolute. CMake finds the prefix from where
//! the config file is when it loads it, so the config keeps working
//! after the staged tree is copied to `/usr`, or if the whole install is
//! moved somewhere else.
//!
//! There is one exception to that. If a directory is outside the prefix,
//! for example because `--prefix-lib-dir` is an absolute path somewhere
//! else, the config reaches it with `..` steps from the prefix. That is
//! still correct where the files are installed, but moving the prefix on
//! its own would break it.

const std = @import("std");
const configure_file = @import("configure_file.zig");
const InstallDirs = @import("InstallDirs");

pub fn main(init: std.process.Init) !void {
    // The process exits right after writing its output, so allocate
    // everything from the arena and never free.
    const alloc = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(alloc);
    if (args.len < 2 + InstallDirs.run_arg_count) {
        std.log.err(
            "usage: cmake_package_config <template> [NAME=VALUE]... <prefix> <bindir> <libdir> <includedir>",
            .{},
        );
        std.process.exit(1);
    }
    const template = args[1];
    const dirs_start = args.len - InstallDirs.run_arg_count;
    const dirs: InstallDirs = try .fromRunArgs(alloc, io, init.environ_map, args[dirs_start..]);

    const config_dir = try std.fs.path.join(alloc, &.{ dirs.lib, "cmake", "ghostty-vt" });
    const to_prefix = try InstallDirs.relative(alloc, config_dir, dirs.prefix);

    var values: std.StringArrayHashMapUnmanaged([]const u8) = .empty;

    // This is the code CMake's configure_package_config_file() puts in
    // place of @PACKAGE_INIT@. It sets PACKAGE_PREFIX_DIR, and defines
    // check_required_components(), which the template calls at the end.
    //
    // CMake's version also handles installs where /usr is a symlink to
    // another directory, by comparing against the install prefix it knew
    // when it was configured. That would put an absolute path in the
    // config, so it is left out here.
    try values.put(alloc, "PACKAGE_INIT", try std.fmt.allocPrint(alloc,
        \\get_filename_component(PACKAGE_PREFIX_DIR "${{CMAKE_CURRENT_LIST_DIR}}/{s}/" ABSOLUTE)
        \\
        \\macro(check_required_components _NAME)
        \\  foreach(comp ${{${{_NAME}}_FIND_COMPONENTS}})
        \\    if(NOT ${{_NAME}}_${{comp}}_FOUND)
        \\      if(${{_NAME}}_FIND_REQUIRED_${{comp}})
        \\        set(${{_NAME}}_FOUND FALSE)
        \\      endif()
        \\    endif()
        \\  endforeach()
        \\endmacro()
    , .{to_prefix}));
    try values.put(alloc, "CMAKE_INSTALL_BINDIR", try InstallDirs.relative(alloc, dirs.prefix, dirs.bin));
    try values.put(alloc, "CMAKE_INSTALL_LIBDIR", try InstallDirs.relative(alloc, dirs.prefix, dirs.lib));
    try values.put(alloc, "CMAKE_INSTALL_INCLUDEDIR", try InstallDirs.relative(alloc, dirs.prefix, dirs.include));

    try configure_file.putArgs(alloc, &values, args[2..dirs_start]);
    try configure_file.configure(alloc, io, template, &values);
}
