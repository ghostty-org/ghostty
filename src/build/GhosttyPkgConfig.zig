//! Generates pkg-config `.pc` files at build time. See
//! `src/extra/pkg-config.zig` for the tool that writes them.
//!
//! Usage:
//!
//! ```zig
//! const pkg_config: GhosttyPkgConfig = try .init(b, .{
//!     .name = "ghostty-vt",
//!     .description = "Ghostty VT library",
//!     .version = version,
//!     .libs = &.{ "-L${libdir}", "-lghostty-vt" },
//! });
//! b.getInstallStep().dependOn(&b.addInstallFileWithDir(
//!     pkg_config.getSharedFile(),
//!     .lib,
//!     "pkgconfig/libghostty-vt.pc",
//! ).step);
//! ```
const GhosttyPkgConfig = @This();

const std = @import("std");
const InstallDirs = @import("InstallDirs.zig");
const Build = std.Build;
const Step = Build.Step;
const LazyPath = Build.LazyPath;

owner: *Build,

/// The tool that writes the files, built for the host.
generator: *Step.Compile,

/// The values from `Options`, compiled into `generator`.
options: *Step.Options,

/// What the `.pc` files say. The `_static` fields apply to the static
/// file and fall back to the shared value when null.
///
/// Values in `cflags`, `libs` and their `_static` fields may use the
/// `${libdir}` and `${includedir}` variables that every generated file
/// defines.
pub const Options = struct {
    /// The `Name:` field, for example "ghostty-vt".
    name: []const u8,
    name_static: ?[]const u8 = null,

    /// The `Description:` field, a short sentence about the library.
    description: []const u8,
    description_static: ?[]const u8 = null,

    /// The `Version:` field.
    version: std.SemanticVersion,

    /// The `Cflags:` field, as separate flags that are joined with
    /// spaces, for example `&.{"-I${includedir}"}`.
    cflags: []const []const u8 = &.{"-I${includedir}"},
    cflags_static: ?[]const []const u8 = null,

    /// The `Libs:` field, as separate flags that are joined with spaces,
    /// for example `&.{ "-L${libdir}", "-lghostty-vt" }`.
    libs: []const []const u8 = &.{},
    libs_static: ?[]const []const u8 = null,

    /// The `Libs.private:` field, for libraries that only static linking
    /// needs, for example `&.{"-lc++"}`. Shared by both files.
    libs_private: []const []const u8 = &.{},

    /// The `Requires.private:` field, for other pkg-config modules that
    /// only static linking needs, for example `&.{"simdutf"}`. Shared by
    /// both files.
    reqs_private: []const []const u8 = &.{},

    /// Whether the files find the install tree relative to their own
    /// location instead of through the absolute install prefix. Applies
    /// to both files.
    ///
    /// pkg-config sets the `${pcfiledir}` variable to the directory that
    /// holds the `.pc` file it is reading. With this option on, the files
    /// use it to reach the prefix, so the whole install tree can be moved
    /// or unzipped anywhere and still work. For the default layout, where
    /// the files are in `<prefix>/lib/pkgconfig`, the files start with:
    ///
    ///     prefix=${pcfiledir}/../..
    ///     includedir=${prefix}/include
    ///     libdir=${prefix}/lib
    ///
    /// Turn this on for trees that are shipped as archives, such as the
    /// prebuilt Windows zips. Leave it off for system installs.
    /// Distribution packages expect the absolute prefix, for example
    /// `prefix=/usr`.
    relocatable: bool = false,
};

/// Builds the generator with `opts` compiled in. Call `getSharedFile` or
/// `getStaticFile` to get the files.
pub fn init(b: *Build, opts: Options) !GhosttyPkgConfig {
    const generator = b.addExecutable(.{
        .name = "pkg-config-generator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/extra/pkg-config.zig"),
            .target = b.graph.host,
            .optimize = .debug,
        }),
    });

    const cflags = try std.mem.join(b.allocator, " ", opts.cflags);
    const cflags_static = if (opts.cflags_static) |s| try std.mem.join(b.allocator, " ", s) else cflags;
    const libs = try std.mem.join(b.allocator, " ", opts.libs);
    const libs_static = if (opts.libs_static) |s| try std.mem.join(b.allocator, " ", s) else libs;

    const options = b.addOptions();
    options.addOption([]const u8, "name", opts.name);
    options.addOption([]const u8, "name_static", opts.name_static orelse opts.name);
    options.addOption([]const u8, "description", opts.description);
    options.addOption([]const u8, "description_static", opts.description_static orelse opts.description);
    options.addOption(std.SemanticVersion, "version", opts.version);
    options.addOption([]const u8, "cflags", cflags);
    options.addOption([]const u8, "cflags_static", cflags_static);
    options.addOption([]const u8, "libs", libs);
    options.addOption([]const u8, "libs_static", libs_static);
    options.addOption([]const u8, "libs_private", try std.mem.join(b.allocator, " ", opts.libs_private));
    options.addOption([]const u8, "reqs_private", try std.mem.join(b.allocator, " ", opts.reqs_private));
    options.addOption(bool, "relocatable", opts.relocatable);
    generator.root_module.addOptions("options", options);
    generator.root_module.addImport("InstallDirs", b.createModule(.{
        .root_source_file = b.path("src/build/InstallDirs.zig"),
    }));

    return .{
        .owner = b,
        .generator = generator,
        .options = options,
    };
}

/// Returns the `.pc` file for linking against the shared library.
pub fn getSharedFile(self: *const GhosttyPkgConfig) LazyPath {
    return self.generate("shared");
}

/// Returns the `.pc` file for linking against the static library. It
/// uses the `_static` options where they are set.
pub fn getStaticFile(self: *const GhosttyPkgConfig) LazyPath {
    return self.generate("static");
}

/// Adds a step that runs the generator for `kind` ("shared" or "static")
/// and returns its output.
fn generate(self: *const GhosttyPkgConfig, kind: []const u8) LazyPath {
    const run = self.owner.addRunArtifact(self.generator);
    run.addArg(kind);
    InstallDirs.addRunArgs(run);
    return run.captureStdOut(.{});
}
