const GhosttyLibVt = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The install step for the library output.
artifact: *std.Build.Step,

/// The kind of library
kind: Kind,

/// The final library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,
pkg_config_static: ?std.Build.LazyPath,

/// The kind of library being built. This is similar to LinkMode but
/// also includes wasm which is an executable, not a library.
const Kind = enum {
    wasm,
    shared,
    static,
};

pub fn initWasm(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    const target = zig.vt.resolved_target.?;
    assert(target.result.cpu.arch.isWasm());

    const exe = b.addExecutable(.{
        .name = "ghostty-vt",
        .root_module = zig.vt_c,
        .version = zig.version,
    });

    // Allow exported symbols to actually be exported.
    exe.rdynamic = true;

    // Export the indirect function table so that embedders (e.g. JS in
    // a browser) can insert callback entries for terminal effects.
    exe.export_table = true;

    // There is no entrypoint for this wasm module.
    exe.entry = .disabled;

    // Zig's WASM linker doesn't support --growable-table, so the table
    // is emitted with max == min and can't be grown from JS. Run a
    // small Zig build tool that patches the binary's table section to
    // remove the max limit.
    const patch_run = patch: {
        const patcher = b.addExecutable(.{
            .name = "wasm_patch_growable_table",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/wasm_patch_growable_table.zig"),
                .target = b.graph.host,
            }),
        });
        break :patch b.addRunArtifact(patcher);
    };
    patch_run.addFileArg(exe.getEmittedBin());
    const output = patch_run.addOutputFileArg("ghostty-vt.wasm");
    const artifact_install = b.addInstallFileWithDir(
        output,
        .bin,
        "ghostty-vt.wasm",
    );

    return .{
        .step = &patch_run.step,
        .artifact = &artifact_install.step,
        .kind = .wasm,
        .output = output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}

pub fn initStatic(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    return initLib(b, zig, .static);
}

pub fn initShared(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    return initLib(b, zig, .dynamic);
}

/// Apple platform targets for xcframework slices.
pub const ApplePlatform = enum {
    macos_universal,
    ios,
    ios_simulator,
    // tvOS, watchOS, and visionOS are not yet supported by Zig's
    // standard library (missing PATH_MAX, mcontext fields, etc.).

    /// Platforms that have device + simulator pairs, gated on SDK detection.
    const sdk_platforms = [_]struct {
        os_tag: std.Target.Os.Tag,
        device: ApplePlatform,
        simulator: ApplePlatform,
    }{
        .{ .os_tag = .ios, .device = .ios, .simulator = .ios_simulator },
    };
};

/// Static libraries for each Apple platform, keyed by `ApplePlatform`.
pub const AppleLibs = std.EnumMap(ApplePlatform, GhosttyLibVt);

/// Build static libraries for all available Apple platforms.
/// Always builds a macOS universal (arm64 + x86_64) fat binary.
/// Additional platforms are included if their SDK is detected.
pub fn initStaticAppleUniversal(
    b: *std.Build,
    cfg: *const Config,
    deps: *const SharedDeps,
    zig: *const GhosttyZig,
) !AppleLibs {
    var result: AppleLibs = .{};

    // macOS universal (arm64 + x86_64)
    const aarch64_zig = try zig.retarget(
        b,
        cfg,
        deps,
        Config.genericMacOSTarget(b, .aarch64),
    );
    const x86_64_zig = try zig.retarget(
        b,
        cfg,
        deps,
        Config.genericMacOSTarget(b, .x86_64),
    );
    const aarch64 = try initStatic(b, &aarch64_zig);
    const x86_64 = try initStatic(b, &x86_64_zig);
    const universal = LipoStep.create(b, .{
        .name = "ghostty-vt",
        .out_name = "libghostty-vt.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });
    result.put(.macos_universal, .{
        .step = universal.step,
        .artifact = universal.step,
        .kind = .static,
        .output = universal.output,
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    });

    // Additional Apple platforms, each gated on SDK availability.
    for (ApplePlatform.sdk_platforms) |p| {
        const target_query: std.Target.Query = .{
            .cpu_arch = .aarch64,
            .os_tag = p.os_tag,
            .os_version_min = Config.osVersionMin(p.os_tag),
        };
        if (detectAppleSDK(b, b.resolveTargetQuery(target_query).result)) {
            const dev_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(target_query));
            result.put(p.device, try initStatic(b, &dev_zig));

            const sim_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = p.os_tag,
                .os_version_min = Config.osVersionMin(p.os_tag),
                .abi = .simulator,
                .cpu_model = .{ .explicit = &std.Target.aarch64.cpu.apple_a17 },
            }));
            result.put(p.simulator, try initStatic(b, &sim_zig));
        }
    }

    return result;
}

fn initLib(
    b: *std.Build,
    zig: *const GhosttyZig,
    linkage: std.builtin.LinkMode,
) !GhosttyLibVt {
    const kind: Kind = switch (linkage) {
        .static => .static,
        .dynamic => .shared,
    };
    const target = zig.vt.resolved_target.?;
    const lib = b.addLibrary(.{
        .name = if (kind == .static) "ghostty-vt-static" else "ghostty-vt",
        .linkage = linkage,
        .root_module = zig.vt_c,
        .version = zig.version,
    });
    lib.installHeadersDirectory(
        b.path("include/ghostty"),
        "ghostty",
        .{ .include_extensions = &.{".h"} },
    );

    if (kind == .static) {
        // These must be bundled since we're compiling into a static lib.
        // Otherwise, you get undefined symbol errors. This could cause
        // problems if you're linking multiple static Zig libraries but
        // we'll cross that bridge when we get to it.
        lib.bundle_compiler_rt = true;
        lib.bundle_ubsan_rt = true;

        // Enable PIC so the static library can be linked into PIE
        // executables, which is the default on most Linux distributions.
        lib.root_module.pic = true;
    }

    if (target.result.os.tag == .windows) {
        // Zig's ubsan emits /exclude-symbols linker directives that
        // are incompatible with the MSVC linker (LNK4229).
        lib.bundle_ubsan_rt = false;
    }

    if (lib.rootModuleTarget().abi.isAndroid()) {
        // Support 16kb page sizes, required for Android 15+.
        lib.link_z_max_page_size = 16384; // 16kb

        try @import("android_ndk").addPaths(b, lib);
    }

    if (lib.rootModuleTarget().os.tag.isDarwin()) {
        // Self-hosted x86_64 doesn't work for darwin. It may not work
        // for other platforms too but definitely darwin.
        lib.use_llvm = true;

        // This is required for codesign and dynamic linking to work.
        lib.headerpad_max_install_names = true;

        // If we're not cross compiling then we try to find the Apple
        // SDK using standard Apple tooling.
        if (builtin.os.tag.isDarwin()) try @import("apple_sdk").addPaths(b, lib);
    }

    // Get our debug symbols (only for shared libs; static libs aren't linked)
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (kind != .shared) break :dsymutil null;
        if (!target.result.os.tag.isDarwin()) break :dsymutil null;

        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libghostty-vt.dSYM");
        break :dsymutil output;
    };

    // pkg-config
    //
    // pkg-config's --static only expands Libs.private / Requires.private;
    // it doesn't change -lghostty-vt into an archive-only reference when
    // both shared and static libraries are installed. Install a dedicated
    // static module so consumers can request the archive explicitly.
    const pcs: ?PkgConfigFiles = if (kind == .shared)
        pkgConfigFiles(b, zig, target.result.os.tag)
    else
        null;

    // For static libraries with vendored SIMD dependencies, combine
    // all archives into a single fat archive so consumers only need
    // to link one file.
    if (kind == .static and
        zig.simd_libs.items.len > 0)
    {
        var sources: SharedDeps.LazyPathList = .empty;
        try sources.append(b.allocator, lib.getEmittedBin());
        try sources.appendSlice(b.allocator, zig.simd_libs.items);

        const combined = combineArchives(b, target, sources.items);
        combined.step.dependOn(&lib.step);

        return .{
            .step = combined.step,
            .artifact = &b.addInstallArtifact(lib, .{}).step,
            .kind = kind,
            .output = combined.output,
            .dsym = dsymutil,
            .pkg_config = if (pcs) |v| v.shared else null,
            .pkg_config_static = if (pcs) |v| v.static else null,
        };
    }

    return .{
        .step = &lib.step,
        .artifact = &b.addInstallArtifact(lib, .{}).step,
        .kind = kind,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = if (pcs) |v| v.shared else null,
        .pkg_config_static = if (pcs) |v| v.static else null,
    };
}

/// Combine multiple static archives into a single fat archive.
/// Uses libtool on Darwin and ar MRI scripts on other platforms.
fn combineArchives(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    if (target.result.os.tag.isDarwin()) {
        const libtool = LibtoolStep.create(b, .{
            .name = "ghostty-vt",
            .out_name = "libghostty-vt.a",
            .sources = @constCast(sources),
        });
        return .{ .step = libtool.step, .output = libtool.output };
    }

    // On non-Darwin, use a build tool that generates an MRI script and
    // pipes it to `zig ar -M`. This works on all platforms including
    // Windows (the previous /bin/sh approach did not).
    const tool = b.addExecutable(.{
        .name = "combine_archives",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/build/combine_archives.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addArg(b.graph.zig_exe);
    const output = run.addOutputFileArg("libghostty-vt.a");
    for (sources) |source| run.addFileArg(source);

    return .{ .step = &run.step, .output = output };
}

/// Returns the Libs.private value for the pkg-config file.
/// Vendored C++ dependencies are built in no-libcxx mode so consumers
/// don't need libc++.  System-provided simdutf still requires it.
fn libsPrivate(
    zig: *const GhosttyZig,
) []const u8 {
    return if (zig.vt_c.link_libcpp orelse false) "-lc++" else "";
}

const PkgConfigFiles = struct {
    shared: std.Build.LazyPath,
    static: std.Build.LazyPath,
};

fn pkgConfigFiles(
    b: *std.Build,
    zig: *const GhosttyZig,
    os_tag: std.Target.Os.Tag,
) PkgConfigFiles {
    const wf = b.addWriteFiles();
    const libs_private = libsPrivate(zig);
    const requires_private = requiresPrivate(b);

    return .{
        .shared = wf.add("libghostty-vt.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libghostty-vt
            \\URL: https://github.com/ghostty-org/ghostty
            \\Description: Ghostty VT library
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lghostty-vt
            \\Libs.private: {s}
            \\Requires.private: {s}
        , .{ b.install_prefix, zig.version, libs_private, requires_private })),
        .static = wf.add("libghostty-vt-static.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libghostty-vt-static
            \\URL: https://github.com/ghostty-org/ghostty
            \\Description: Ghostty VT library (static)
            \\Version: {f}
            \\Cflags: -I${{includedir}}
            \\Libs: ${{libdir}}/{s}
            \\Libs.private: {s}
            \\Requires.private: {s}
        , .{
            b.install_prefix,
            zig.version,
            staticLibraryName(os_tag),
            libs_private,
            requires_private,
        })),
    };
}

fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-vt-static.lib"
    else
        "libghostty-vt.a";
}

/// Returns the Requires.private value for the pkg-config file.
/// When SIMD dependencies are provided by the system (via
/// -Dsystem-integration), we reference their pkg-config names so
/// that downstream consumers pick them up transitively.
fn requiresPrivate(b: *std.Build) []const u8 {
    const system_simdutf = b.systemIntegrationOption("simdutf", .{});
    const system_highway = b.systemIntegrationOption("highway", .{ .default = false });

    if (system_simdutf and system_highway) return "simdutf, libhwy";
    if (system_simdutf) return "simdutf";
    if (system_highway) return "libhwy";
    return "";
}

/// Create an XCFramework bundle from Apple platform static libraries.
pub fn xcframework(
    apple_libs: *const AppleLibs,
    b: *std.Build,
) *XCFrameworkStep {
    // Generate a headers directory with a module map for Swift PM.
    // We can't use include/ directly because it contains a module map
    // for GhosttyKit (the macOS app library).
    const wf = b.addWriteFiles();
    _ = wf.addCopyDirectory(
        b.path("include/ghostty"),
        "ghostty",
        .{ .include_extensions = &.{".h"} },
    );
    _ = wf.add("module.modulemap",
        \\module GhosttyVt {
        \\    umbrella header "ghostty/vt.h"
        \\    export *
        \\}
        \\
    );
    const headers = wf.getDirectory();

    var libraries: [AppleLibs.len]XCFrameworkStep.Library = undefined;
    var lib_count: usize = 0;
    for (std.enums.values(ApplePlatform)) |platform| {
        if (apple_libs.get(platform)) |lib| {
            libraries[lib_count] = .{
                .library = lib.output,
                .headers = headers,
                .dsym = null,
            };
            lib_count += 1;
        }
    }

    return XCFrameworkStep.create(b, .{
        .name = "ghostty-vt",
        .out_path = b.pathJoin(&.{ b.install_prefix, "lib/ghostty-vt.xcframework" }),
        .libraries = libraries[0..lib_count],
    });
}

/// Returns true if the Apple SDK for the given target is installed.
fn detectAppleSDK(b: *std.Build, target: std.Target) bool {
    _ = std.zig.LibCInstallation.findNative(
        b.allocator,
        b.graph.io,
        .{
            .target = &target,
            .verbose = false,
        },
    ) catch return false;
    return true;
}

pub fn install(
    self: *const GhosttyLibVt,
    step: *std.Build.Step,
) void {
    const b = step.owner;
    step.dependOn(self.artifact);
    if (self.pkg_config) |pkg_config| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config,
            .prefix,
            "share/pkgconfig/libghostty-vt.pc",
        ).step);
    }
    if (self.pkg_config_static) |pkg_config_static| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config_static,
            .prefix,
            "share/pkgconfig/libghostty-vt-static.pc",
        ).step);
    }
}
