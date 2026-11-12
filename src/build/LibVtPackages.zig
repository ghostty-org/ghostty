//! The `lib-vt-packages` build step, which reports the packages a
//! libghostty-vt build uses. Package maintainers use the report to list the
//! third-party code inside the library, with its license and version.
//!
//! You normally do not run this step yourself.
//! nix/build-support/gen-lib-vt-deps.sh runs it for every supported target
//! and turns the results into deps/libghostty-vt-third-party.json. To see the
//! report for one target:
//!
//!   zig build lib-vt-packages -Demit-lib-vt --prefix /tmp/report
//!   cat /tmp/report/lib-vt-packages.json
//!
//! The report has one entry for Ghostty and one for every package Zig
//! fetched or found for the build:
//!
//!   {
//!     "packages": [
//!       {
//!         "hash": "pkg/highway",
//!         "version": "1.2.0",
//!         "linked_paths": ["src/cpp", "src/cpp/targets.cpp", ...],
//!         "third_party": [
//!           {
//!             "name": "highway",
//!             "license": "Apache-2.0 OR BSD-3-Clause",
//!             "version": "1.2.0",
//!             "path": null,
//!             "url": null
//!           }
//!         ]
//!       },
//!       ...
//!     ]
//!   }
//!
//!   hash          How Zig identifies the package. For a fetched package,
//!                 this is its hash, as in deps/packages.json. For a
//!                 package in this repository, it is the package's
//!                 directory, such as "pkg/highway". Ghostty itself is "".
//!   version       The .version field of the package's build.zig.zon, or
//!                 null if it has none.
//!   linked_paths  The package's files and directories that are compiled
//!                 into the library, relative to the package. Empty if
//!                 nothing is. See "What counts as linked" below.
//!   third_party   The .third_party field of the package's build.zig.zon.
//!
//! # The `.third_party` field
//!
//! Zig packages do not record their license, and the C projects we depend
//! on usually have no build.zig.zon to record a version in. So each
//! build.zig.zon in this repository describes the third-party code it
//! brings in, in a `.third_party` field next to the URLs that fetch it:
//!
//!   .dependencies = .{
//!       .wuffs = .{ .url = "...", .hash = "..." },
//!       .pixels = .{ .url = "...", .hash = "..." },
//!   },
//!   .third_party = .{
//!       .{ .name = "pixels", .license = "CC0-1.0" },
//!       .{ .name = "wuffs", .license = "Apache-2.0 OR MIT", .version = "0.4.0-alpha.10" },
//!   },
//!
//! Zig ignores fields it does not know, so `.third_party` has no effect on the
//! build. The fields of each entry are documented on `ThirdParty`.
//!
//! Code copied into this repository ("vendored" code) is described the same
//! way, with a `path` to the directory that holds it. Its version is the
//! `.version` of the build.zig.zon the entry is in:
//!
//!   .name = .simdutf,
//!   .version = "9.0.0",
//!   ...
//!   .third_party = .{
//!       .{
//!           .name = "simdutf",
//!           .license = "Apache-2.0 OR MIT",
//!           .path = "vendor",
//!           .url = "https://github.com/simdutf/simdutf",
//!       },
//!   },
//!
//! # What counts as linked
//!
//! A file counts as compiled into the library when the library's build
//! reaches it. Starting from the library's root module, the step follows
//! every imported module and every linked library, and collects each Zig
//! root source file, C source file, include directory, and object file.
//!
//! This can include too much, but never too little. Zig only compiles the
//! parts of a Zig file that are used, so a reachable file may add nothing to
//! the library. For example, translate_c's helper functions are reachable
//! from every translated C header, but a header may not use them.
//!
//! Generated files and system paths, such as an SDK's headers, belong to no
//! package and are left out.
const LibVtPackages = @This();

const std = @import("std");
const Module = std.Build.Module;
const LazyPath = std.Build.LazyPath;

/// The step that installs lib-vt-packages.json.
step: *std.Build.Step,

/// One entry in the `.third_party` field of a build.zig.zon.
pub const ThirdParty = struct {
    /// The package's name in deps/packages.json. For vendored code, any
    /// name that identifies the project.
    name: []const u8,

    /// The SPDX license expression for the package, such as "MIT" or
    /// "Apache-2.0 OR MIT". Use OR when you may choose either license, and
    /// AND when both apply. Check the package's license files: some
    /// packages also include data, such as Unicode tables, under a second
    /// license.
    license: []const u8,

    /// The upstream version. Set this only for packages without a
    /// build.zig.zon of their own. A package that declares its own version
    /// uses that one, and vendored code uses the version of the
    /// build.zig.zon that holds it. gen-lib-vt-deps.sh rejects an entry
    /// that sets a second version.
    version: ?[]const u8 = null,

    /// For vendored code only: the directory that holds it, relative to the
    /// build.zig.zon this entry is in.
    path: ?[]const u8 = null,

    /// For vendored code only: where the code comes from.
    url: ?[]const u8 = null,
};

/// The fields of a build.zig.zon that the report reads.
const Manifest = struct {
    version: ?[]const u8 = null,
    third_party: []const ThirdParty = &.{},
};

/// One package in the report.
const Package = struct {
    hash: []const u8,
    version: ?[]const u8,
    linked_paths: []const []const u8,
    third_party: []const ThirdParty,
};

/// Defines the `lib-vt-packages` step. `root` is the root module of
/// libghostty-vt. Every library variant (shared, static, and wasm) is built
/// from it.
///
/// The report is computed here, while build.zig runs. A build.zig.zon with
/// a malformed `.third_party` field fails only this step, so ordinary library
/// builds are never affected.
pub fn init(b: *std.Build, root: *Module) !LibVtPackages {
    const step = b.step(
        "lib-vt-packages",
        "Write lib-vt-packages.json, the packages libghostty-vt uses",
    );

    const json = report(b, root) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            step.dependOn(&b.addFail(b.fmt(
                "lib-vt-packages: {t}, see the error above",
                .{err},
            )).step);
            return .{ .step = step };
        },
    };

    const wf = b.addWriteFiles();
    const file = wf.add("lib-vt-packages.json", json);
    step.dependOn(&b.addInstallFileWithDir(
        file,
        .prefix,
        "lib-vt-packages.json",
    ).step);
    return .{ .step = step };
}

/// Builds the JSON report.
fn report(b: *std.Build, root: *Module) ![]const u8 {
    const arena = b.allocator;

    var walk: Walk = .{ .arena = arena };
    try walk.module(root);

    // Ghostty itself, then every package Zig fetched or found for this
    // build. Zig generates this table into the build runner. It includes
    // every required package, even one no build script uses. Optional
    // (lazy) packages that this build never asked for are marked
    // unavailable, and we skip them.
    var packages: std.ArrayList(Package) = .empty;
    try packages.append(arena, try package(b, &walk, "", b.root.root_dir.path orelse "."));
    const all = @import("root").dependencies.packages;
    inline for (@typeInfo(all).@"struct".decl_names) |hash| {
        const pkg = @field(all, hash);
        const available = !@hasDecl(pkg, "available") or pkg.available;
        if (available) try packages.append(arena, try package(b, &walk, hash, pkg.build_root));
    }

    return std.json.Stringify.valueAlloc(
        arena,
        .{ .packages = packages.items },
        .{ .whitespace = .indent_2 },
    );
}

/// Describes the package at `build_root`, using the files `walk` found.
fn package(b: *std.Build, walk: *const Walk, hash: []const u8, build_root: []const u8) !Package {
    const manifest = try readManifest(b, build_root);
    return .{
        .hash = hash,
        .version = manifest.version,
        .linked_paths = if (walk.paths.get(hash)) |set| set.keys() else &.{},
        .third_party = manifest.third_party,
    };
}

/// Reads the build.zig.zon in `build_root`. A package without one, such as
/// a plain C source archive, gets an empty manifest.
fn readManifest(b: *std.Build, build_root: []const u8) !Manifest {
    const arena = b.allocator;
    const io = b.graph.io;
    const path = try std.fs.path.join(arena, &.{ build_root, "build.zig.zon" });
    const source = std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        arena,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    ) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };

    // Zig 0.17 caches the result of running build.zig. Tell it the report
    // depends on this file, so editing a .third_party field updates the report.
    b.dependOnFileContents(.{ .cwd_relative = path });

    var diagnostics: std.zon.parse.Diagnostics = undefined;
    return std.zon.parse.fromSlice(Manifest, .{
        .gpa = arena,
        .arena = arena,
        .source = source,
        .diagnostics = &diagnostics,
        .ignore_unknown_fields = true,
    }) catch |err| {
        if (err == error.ParseZon) diagnostics.log(path);
        return err;
    };
}

/// Walks the module graph of the library, collecting the files that each
/// package contributes. See "What counts as linked" above.
const Walk = struct {
    arena: std.mem.Allocator,

    /// Modules already visited. Many modules are imported more than once.
    seen: std.AutoHashMapUnmanaged(*Module, void) = .empty,

    /// For each package hash, the set of package-relative paths found.
    paths: std.StringArrayHashMapUnmanaged(std.StringArrayHashMapUnmanaged(void)) = .empty,

    /// Collects the files of `m` and of every module and library it uses.
    fn module(self: *Walk, m: *Module) error{OutOfMemory}!void {
        if ((try self.seen.getOrPut(self.arena, m)).found_existing) return;

        if (m.root_source_file) |p| try self.add(p, "");

        for (m.include_dirs.items) |dir| switch (dir) {
            .path,
            .path_system,
            .path_after,
            .framework_path,
            .framework_path_system,
            .embed_path,
            => |p| try self.add(p, ""),
            .other_step => |c| try self.module(c.root_module),
            .config_header_step => {},
        };

        for (m.link_objects.items) |obj| switch (obj) {
            .static_path, .assembly_file => |p| try self.add(p, ""),
            .c_source_file => |f| try self.add(f.file, ""),
            .c_source_files => |fs| for (fs.files) |f| try self.add(fs.root, f),
            .other_step => |c| try self.module(c.root_module),
            .system_lib, .win32_resource_file => {},
        };

        for (m.import_table.values()) |imported| try self.module(imported);
    }

    /// Records `p`, joined with `sub_path`, under the package it belongs
    /// to. Paths that belong to no package are ignored.
    fn add(self: *Walk, p: LazyPath, sub_path: []const u8) !void {
        const owner: *std.Build, const base: []const u8 = switch (p) {
            .src_path => |s| .{ s.owner, s.sub_path },
            .dependency => |d| .{ d.dependency.builder, d.sub_path },
            .generated, .cwd_relative, .relative => return,
        };

        const joined = try std.fs.path.resolvePosix(self.arena, &.{ base, sub_path });
        const gop = try self.paths.getOrPut(self.arena, owner.pkg_hash);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.put(self.arena, joined, {});
    }
};
