const GhosttyLibVt = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const RunStep = std.Build.Step.Run;
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");
const LipoStep = @import("LipoStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const XCFrameworkStep = @import("XCFrameworkStep.zig");
const GhosttyPkgConfig = @import("GhosttyPkgConfig.zig");
const InstallDirs = @import("InstallDirs.zig");

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

/// The CMake package config files that let CMake projects use
/// `find_package(ghostty-vt)`. One config describes both the shared and
/// static library, so it is generated with the shared library only and
/// is null for every other kind.
cmake: ?CMakeFiles,

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

    // Default Zig stack size in Zig 0.16 is 1MB. Lower to 128 KB since
    // this has to be preallocated up front in Wasm linear memory. Peak
    // stack under various artificial loads is 17 KB at the time of this
    // comment but lets do 128KB to be safe. We can lower later.
    exe.stack_size = 128 * 1024;

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
        .cmake = null,
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
    is_dep: bool,
) !GhosttyLibVt {
    const target = zig.vt.resolved_target.?;

    // Prefer Apple's linker for final Darwin dylibs when its toolchain is
    // available. Besides producing the platform load commands expected by
    // Apple distribution, this lets the static archive's libSystem symbol
    // override take effect. Cross-compiled macOS dylibs continue through Zig.
    //
    // A Zig dependent gets the Zig-linked library instead. The native link
    // is a Run step, and dep.artifact("ghostty-vt") only finds Compile
    // steps installed with addInstallArtifact. The dependent links the
    // library into its own build, so the Apple linker's packaging details
    // (compatibility version, distribution load commands) don't matter
    // there.
    if (!is_dep and @import("apple_sdk").nativeLink.available(target)) {
        return initLibApple(b, zig);
    }

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
        .cmake = null,
    });

    // Additional Apple platforms, each gated on SDK availability.
    for (ApplePlatform.sdk_platforms) |p| {
        const target_query: std.Target.Query = .{
            .cpu_arch = .aarch64,
            .os_tag = p.os_tag,
            .os_version_min = Config.osVersionMinLibVt(p.os_tag),
        };
        if (detectAppleSDK(
            b.graph.io,
            b.allocator,
            &b.graph.environ_map,
            b.resolveTargetQuery(target_query).result,
        )) {
            const dev_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(target_query));
            result.put(p.device, try initStatic(b, &dev_zig));

            const sim_zig = try zig.retarget(b, cfg, deps, b.resolveTargetQuery(.{
                .cpu_arch = .aarch64,
                .os_tag = p.os_tag,
                .os_version_min = Config.osVersionMinLibVt(p.os_tag),
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
    linkage: std.lang.LinkMode,
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
        // Zig names the shared library from this version and records it as
        // the dylib's current version. See SharedVersion.
        .version = zig.version,
    });
    if (kind == .shared and target.result.os.tag.isDarwin()) {
        // Zig has no option for the compatibility version and always writes
        // 1.0.0, so only the install name can follow SharedVersion here.
        lib.install_name = SharedVersion.init(b, zig.version).install_name;
    }
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
        // Native freestanding targets don't have a dynamic loader and some,
        // such as Xtensa, don't support PIC relocations.
        lib.root_module.pic = target.result.os.tag != .freestanding;
    }

    if (target.result.os.tag == .windows) {
        // Zig's ubsan emits /exclude-symbols linker directives that
        // are incompatible with the MSVC linker (LNK4229).
        lib.bundle_ubsan_rt = false;

        if (kind == .static) {
            if (target.result.abi == .msvc) {
                // Zig's compiler runtime doesn't provide MSVC's security
                // cookie symbols when libc is linked. Disable stack-protector
                // generation so static consumers don't need BufferOverflowU.
                lib.root_module.stack_protector = false;
            }

            // The Zig standard library uses NT and kernel32 symbols.
            lib.root_module.linkSystemLibrary("ntdll", .{});
            lib.root_module.linkSystemLibrary("kernel32", .{});
        }
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
        if (builtin.target.os.tag.isDarwin()) try @import("apple_sdk").addPaths(b, lib);
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
        try pkgConfigFiles(b, zig, target.result.os.tag)
    else
        null;
    const cmake: ?CMakeFiles = if (kind == .shared)
        .init(b, zig, target.result)
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

        const combined = CombineArchivesStep.create(b, target, "ghostty-vt", sources.items);
        combined.step.dependOn(&lib.step);

        // On Darwin, prefer libSystem's libc/libm over the bundled
        // compiler-rt for consumers of this archive. See GhosttyLib
        // and libsystem_override.sh for details.
        const override = LibsystemOverrideStep.create(
            b,
            target,
            combined.output,
            "libghostty-vt-fat.a",
        );

        return .{
            .step = override.step orelse combined.step,
            .artifact = &b.addInstallArtifact(lib, .{}).step,
            .kind = kind,
            .output = override.output,
            .dsym = dsymutil,
            .pkg_config = if (pcs) |v| v.shared else null,
            .pkg_config_static = if (pcs) |v| v.static else null,
            .cmake = cmake,
        };
    }

    // Same libSystem preference for the plain (no vendored SIMD)
    // static archive; a no-op off Darwin.
    const override: LibsystemOverrideStep.Result = if (kind == .static) LibsystemOverrideStep.create(
        b,
        target,
        lib.getEmittedBin(),
        "libghostty-vt-static.a",
    ) else .{
        .step = null,
        .output = lib.getEmittedBin(),
    };

    return .{
        .step = override.step orelse &lib.step,
        .artifact = &b.addInstallArtifact(lib, .{}).step,
        .kind = kind,
        .output = override.output,
        .dsym = dsymutil,
        .pkg_config = if (pcs) |v| v.shared else null,
        .pkg_config_static = if (pcs) |v| v.static else null,
        .cmake = cmake,
    };
}

/// Builds a shared Darwin library with Apple's linker.
fn initLibApple(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    // Sorry, this function has a lot of comments because there are
    // a lot of flags that aren't obvious.

    const target = zig.vt.resolved_target.?;
    assert(target.result.os.tag.isDarwin());

    // Build the combined archive through the normal static path first.
    const static = try initStatic(b, zig);

    // Zig's module-level export metadata does not carry into this separate
    // native link, so explicitly expose only libghostty-vt's public C ABI.
    const exports = b.addWriteFiles().add(
        "libghostty-vt.exports",
        "_ghostty_*\n",
    );

    // Use the same file names Zig would, so both linkers install the same
    // files. See SharedVersion.
    const shared_version: SharedVersion = .init(b, zig.version);
    const real_name = shared_version.real_name;
    const soname = shared_version.major_name;

    const native_link = try @import("apple_sdk").nativeLink.addCommand(
        b,
        "link libghostty-vt with Apple ld",
        target,
    );

    native_link.addArgs(&.{
        // Emit a Mach-O dynamic library instead of an executable.
        "-dynamiclib",
        // Pull every object from the combined static archive.
        "-Wl,-all_load",
        // Remove unreachable private code pulled in by all_load.
        "-Wl,-dead_strip",
        // Leave room for packaging tools to rewrite install names.
        "-Wl,-headerpad_max_install_names",
    });
    // Restrict exports to libghostty-vt's public C ABI.
    native_link.addPrefixedFileArg("-Wl,-exported_symbols_list,", exports);
    // With -Dstrip, the objects in the archive have no debug info, but
    // Apple's linker still copies their internal symbol names into the
    // dylib. These flags tell it to leave those out as well.
    if (zig.vt_c.strip orelse false) native_link.addArgs(&.{
        // Leave out the debug map, which points debuggers at the
        // original object files.
        "-Wl,-S",
        // Leave out symbols that aren't exported.
        "-Wl,-x",
    });
    // Link the archive produced by the normal static-library path.
    native_link.addFileArg(static.output);
    native_link.addArgs(&.{
        // The name programs record and load at run time, found via @rpath.
        "-install_name",
        shared_version.install_name,
        // The full library version.
        "-current_version",
        shared_version.current_version,
        // The oldest release with the same ABI.
        "-compatibility_version",
        shared_version.compatibility_version,
        // Write the fully versioned dylib used by the install symlinks.
        "-o",
    });
    const output = native_link.addOutputFileArg(real_name);

    // Recreate addInstallArtifact's dylib layout: install the fully versioned
    // file, then point the major-version and unversioned names at it.
    const artifact_install = b.addInstallFileWithDir(
        output,
        .lib,
        real_name,
    );

    const soname_install = b.addSystemCommand(&.{
        "/bin/ln",
        "-sf",
        real_name,
    });
    soname_install.addDirectoryArg2(.{ .relative = .{
        .base = .install_lib,
        .sub_path = soname,
    } }, .{});
    soname_install.step.dependOn(&artifact_install.step);
    const unversioned_install = b.addSystemCommand(&.{
        "/bin/ln",
        "-sf",
        soname,
    });
    unversioned_install.addDirectoryArg2(.{ .relative = .{
        .base = .install_lib,
        .sub_path = "libghostty-vt.dylib",
    } }, .{});
    unversioned_install.step.dependOn(&soname_install.step);

    // The native link is a Run step rather than a Compile step, so install the
    // public headers explicitly instead of relying on addInstallArtifact.
    const headers_install = b.addInstallDirectory(.{
        .source_dir = b.path("include/ghostty"),
        .install_dir = .header,
        .install_subdir = "ghostty",
        .include_extensions = &.{".h"},
    });
    unversioned_install.step.dependOn(&headers_install.step);

    // Preserve the debug-symbol output exposed by the normal shared-library
    // path for framework and release packaging.
    const dsymutil = RunStep.create(b, "dsymutil");
    dsymutil.addArgs(&.{"dsymutil"});
    dsymutil.addFileArg(output);
    dsymutil.addArgs(&.{"-o"});
    const dsym = dsymutil.addOutputFileArg("libghostty-vt.dSYM");

    const pcs = try pkgConfigFiles(b, zig, target.result.os.tag);
    return .{
        .step = &native_link.step,
        .artifact = &unversioned_install.step,
        .kind = .shared,
        .output = output,
        .dsym = dsym,
        .pkg_config = pcs.shared,
        .pkg_config_static = pcs.static,
        .cmake = .init(b, zig, target.result),
    };
}

/// The version metadata of the libghostty-vt shared library. All of it is
/// derived from `lib_version` here, so every link path agrees.
/// CMakeLists.txt, nix/libghostty-vt.nix and the CI checks compute the same
/// values, so update them together with this.
///
/// The file names are Zig's usual ones. For version 0.1.0:
///
///   | Platform      | File                      | Runtime name                 |
///   | ------------- | ------------------------- | ---------------------------- |
///   | Linux and BSD | libghostty-vt.so.0.1.0    | libghostty-vt.so.0 (SONAME)  |
///   | macOS and iOS | libghostty-vt.0.1.0.dylib | @rpath/libghostty-vt.0.dylib |
///   | Windows       | ghostty-vt.dll            | ghostty-vt.dll               |
///
/// Except on Windows, the runtime name and the unversioned name
/// (libghostty-vt.so or libghostty-vt.dylib) are installed as symlinks to
/// the real file.
///
/// The runtime name only carries the major version. Before 1.0 there is no
/// ABI promise: any minor release may break the ABI, even though 0.1 and
/// 0.2 share a runtime name. Packagers handle that by rebuilding everything
/// that depends on the library whenever the minor version changes. From 1.0
/// on, the library follows semver and only a new major version breaks the
/// ABI.
///
/// macOS and iOS dylibs also record two versions:
///
///   - The current version is the full version, for example 0.1.3.
///   - The compatibility version is the oldest release with the same ABI.
///     Before 1.0 every minor release is its own ABI, so it is 0.<minor>.0
///     (0.1.0 for 0.1.3). From 1.0 on it is <major>.0.0 (1.0.0 for 1.4.2).
///
/// Programs that link against the dylib store its compatibility version,
/// but current versions of dyld don't check it when loading. Treat it as a
/// record of the ABI, not as a guard against loading the wrong release.
///
/// Zig's own linker can't set the compatibility version and always writes
/// 1.0.0. That path is only used for Darwin dylibs built on non-Apple hosts.
const SharedVersion = struct {
    /// The file the linker writes, for example "libghostty-vt.0.1.0.dylib".
    real_name: []const u8,

    /// The file name with only the major version, for example
    /// "libghostty-vt.0.dylib". It is a symlink to `real_name`.
    major_name: []const u8,

    /// The dylib's runtime name, for example "@rpath/libghostty-vt.0.dylib".
    install_name: []const u8,

    /// The full version, for example "0.1.3".
    current_version: []const u8,

    /// The oldest version with the same ABI, for example "0.1.0" for 0.1.3
    /// or "1.0.0" for 1.4.2.
    compatibility_version: []const u8,

    fn init(b: *std.Build, version: std.SemanticVersion) SharedVersion {
        const major_name = b.fmt("libghostty-vt.{d}.dylib", .{version.major});
        return .{
            .real_name = b.fmt("libghostty-vt.{d}.{d}.{d}.dylib", .{
                version.major,
                version.minor,
                version.patch,
            }),
            .major_name = major_name,
            .install_name = b.fmt("@rpath/{s}", .{major_name}),
            .current_version = b.fmt("{d}.{d}.{d}", .{
                version.major,
                version.minor,
                version.patch,
            }),
            .compatibility_version = if (version.major == 0)
                b.fmt("0.{d}.0", .{version.minor})
            else
                b.fmt("{d}.0.0", .{version.major}),
        };
    }
};

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
) !PkgConfigFiles {
    const pkg_config: GhosttyPkgConfig = try .init(b, .{
        .name = "ghostty-vt",
        .name_static = "ghostty-vt-static",
        .description = "Ghostty VT library",
        .description_static = "Ghostty VT library (static)",
        .version = zig.version,
        .libs = &.{ "-L${libdir}", "-lghostty-vt" },
        .libs_static = &.{b.fmt("${{libdir}}/{s}", .{staticLibraryName(os_tag)})},
        .libs_private = &.{libsPrivate(zig)},
        .reqs_private = &.{requiresPrivate(b)},
    });

    return .{
        .shared = pkg_config.getSharedFile(),
        .static = pkg_config.getStaticFile(),
    };
}

fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-vt-static.lib"
    else
        "libghostty-vt.a";
}

/// The file names the shared library is installed under, which the CMake
/// config needs to point at the right files. They follow the naming
/// policy documented on `SharedVersion`.
///
/// For version 0.1.0, the names are:
///
///     Linux:   real = "libghostty-vt.so.0.1.0", soname = "libghostty-vt.so.0"
///     macOS:   real = "libghostty-vt.0.1.0.dylib", soname = "libghostty-vt.0.dylib"
///     Windows: real = "ghostty-vt.dll", implib = "ghostty-vt.lib"
///
/// On macOS the config adds the "@rpath/" prefix to the soname itself.
const SharedLibraryNames = struct {
    /// The library file itself. On Windows this is the DLL, which is
    /// installed to bin/. Everywhere else it is in lib/.
    real: []const u8,

    /// The name a program records when it links against the library,
    /// and looks for again at run time. Null on Windows.
    soname: ?[]const u8,

    /// The import library that programs link against on Windows,
    /// installed to lib/. Null everywhere else.
    implib: ?[]const u8,

    /// Returns the installed shared library names for `os_tag`.
    fn init(
        b: *std.Build,
        version: std.SemanticVersion,
        os_tag: std.Target.Os.Tag,
    ) SharedLibraryNames {
        if (os_tag == .windows) return .{
            .real = "ghostty-vt.dll",
            .soname = null,
            .implib = "ghostty-vt.lib",
        };

        if (os_tag.isDarwin()) {
            const shared_version: SharedVersion = .init(b, version);
            return .{
                .real = shared_version.real_name,
                .soname = shared_version.major_name,
                .implib = null,
            };
        }

        return .{
            .real = b.fmt("libghostty-vt.so.{d}.{d}.{d}", .{
                version.major,
                version.minor,
                version.patch,
            }),
            .soname = b.fmt("libghostty-vt.so.{d}", .{version.major}),
            .implib = null,
        };
    }
};

/// The two files CMake looks for when a project calls
/// `find_package(ghostty-vt)`.
const CMakeFiles = struct {
    /// `ghostty-vt-config.cmake`, which defines the imported targets
    /// `ghostty-vt::ghostty-vt` (shared) and `ghostty-vt::ghostty-vt-static`.
    config: std.Build.LazyPath,

    /// `ghostty-vt-config-version.cmake`, which CMake uses to check
    /// that this install matches the version the project asked for.
    version: std.Build.LazyPath,

    /// Generates the CMake package config for `find_package(ghostty-vt)`.
    ///
    /// The config is made from the same template that the CMake wrapper
    /// (the top-level CMakeLists.txt) uses, so a `zig build` install and a
    /// `cmake --install` define the same targets.
    ///
    /// Every path in the config is relative to the config file itself, so
    /// the install keeps working when it is staged with `DESTDIR` or moved
    /// somewhere else. For example, a config installed at
    ///
    ///     /opt/ghostty/lib/cmake/ghostty-vt/ghostty-vt-config.cmake
    ///
    /// finds the prefix by going up three directories to `/opt/ghostty`,
    /// and expects the library and headers in `/opt/ghostty/lib` and
    /// `/opt/ghostty/include`. With `--prefix-lib-dir lib64` the config
    /// goes in `lib64/cmake/ghostty-vt/` and expects the library in
    /// `lib64`. The values that depend on these directories are filled in
    /// at build time by `cmake_package_config.zig`.
    fn init(
        b: *std.Build,
        zig: *const GhosttyZig,
        target: std.Target,
    ) CMakeFiles {
        const names: SharedLibraryNames = .init(b, zig.version, target.os.tag);

        const generator = b.addExecutable(.{
            .name = "cmake_package_config",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/build/cmake_package_config.zig"),
                .target = b.graph.host,
            }),
        });
        generator.root_module.addImport("InstallDirs", b.createModule(.{
            .root_source_file = b.path("src/build/InstallDirs.zig"),
        }));
        const run = b.addRunArtifact(generator);
        run.addFileArg(b.path("dist/cmake/ghostty-vt-config.cmake.in"));
        run.addArgs(&.{
            b.fmt("GHOSTTY_VT_REALNAME={s}", .{names.real}),
            b.fmt("GHOSTTY_VT_SONAME={s}", .{names.soname orelse ""}),
            b.fmt("GHOSTTY_VT_IMPLIB={s}", .{names.implib orelse ""}),
            b.fmt("GHOSTTY_VT_STATIC_REALNAME={s}", .{staticLibraryName(target.os.tag)}),
        });
        InstallDirs.addRunArgs(run);

        // The version file tells find_package() whether this install
        // satisfies the version a project asked for. It follows the ABI
        // policy documented on SharedVersion: before 1.0 every minor
        // release may break the ABI, and from 1.0 on only a new major
        // release does. So an install of 0.1.2 satisfies a request for
        // 0.1 or 0.1.1, but not 0.2, and an install of 1.4.2 satisfies
        // 1.0 or 1.3, but not 2.0.
        //
        // These are the same rules as CMake's
        // write_basic_package_version_file() with COMPATIBILITY
        // SameMinorVersion before 1.0 and SameMajorVersion after, which
        // is what the CMake wrapper uses. Writing the file by hand keeps
        // CMake out of the build and makes the policy easy to read.
        //
        // The version is written without any pre-release suffix (such as
        // "-dev") because CMake can't compare versions that have one.
        //
        // The file also rejects an install built for a different pointer
        // size, such as a 32-bit library found by a 64-bit project.
        const version = b.fmt("{d}.{d}.{d}", .{
            zig.version.major,
            zig.version.minor,
            zig.version.patch,
        });

        // The releases that share this release's ABI, from abi_first up
        // to but not including abi_next. For example 0.1 to 0.2, or 1 to 2.
        const abi_first, const abi_next = if (zig.version.major == 0) .{
            b.fmt("0.{d}", .{zig.version.minor}),
            b.fmt("0.{d}", .{zig.version.minor + 1}),
        } else .{
            b.fmt("{d}", .{zig.version.major}),
            b.fmt("{d}", .{zig.version.major + 1}),
        };

        const ptr_size = target.ptrBitWidth() / 8;
        const version_file = b.addWriteFiles().add(
            "ghostty-vt-config-version.cmake",
            b.fmt(
                \\# Generated by `zig build`. This follows the same rules as CMake's
                \\# write_basic_package_version_file() with COMPATIBILITY SameMinorVersion
                \\# before 1.0 and SameMajorVersion from 1.0 on.
                \\
                \\set(PACKAGE_VERSION "{[version]s}")
                \\
                \\# Releases from {[first]s} up to, but not including, {[next]s} have the same
                \\# ABI as this one.
                \\set(_ghostty_vt_abi_first "{[first]s}")
                \\set(_ghostty_vt_abi_next "{[next]s}")
                \\
                \\set(PACKAGE_VERSION_COMPATIBLE FALSE)
                \\if(PACKAGE_FIND_VERSION_RANGE)
                \\  # The whole range must have this release's ABI, and must
                \\  # include this release.
                \\  if(PACKAGE_FIND_VERSION_MIN VERSION_GREATER_EQUAL _ghostty_vt_abi_first
                \\      AND PACKAGE_FIND_VERSION_MIN VERSION_LESS _ghostty_vt_abi_next
                \\      AND PACKAGE_VERSION VERSION_GREATER_EQUAL PACKAGE_FIND_VERSION_MIN)
                \\    if(PACKAGE_FIND_VERSION_RANGE_MAX STREQUAL "INCLUDE")
                \\      if(PACKAGE_FIND_VERSION_MAX VERSION_LESS _ghostty_vt_abi_next
                \\          AND PACKAGE_VERSION VERSION_LESS_EQUAL PACKAGE_FIND_VERSION_MAX)
                \\        set(PACKAGE_VERSION_COMPATIBLE TRUE)
                \\      endif()
                \\    elseif(PACKAGE_FIND_VERSION_MAX VERSION_LESS_EQUAL _ghostty_vt_abi_next
                \\        AND PACKAGE_VERSION VERSION_LESS PACKAGE_FIND_VERSION_MAX)
                \\      set(PACKAGE_VERSION_COMPATIBLE TRUE)
                \\    endif()
                \\  endif()
                \\else()
                \\  # The requested version must have this release's ABI, and must
                \\  # not be newer than this release.
                \\  if(PACKAGE_FIND_VERSION VERSION_GREATER_EQUAL _ghostty_vt_abi_first
                \\      AND PACKAGE_FIND_VERSION VERSION_LESS _ghostty_vt_abi_next
                \\      AND PACKAGE_VERSION VERSION_GREATER_EQUAL PACKAGE_FIND_VERSION)
                \\    set(PACKAGE_VERSION_COMPATIBLE TRUE)
                \\  endif()
                \\  if(PACKAGE_FIND_VERSION STREQUAL PACKAGE_VERSION)
                \\    set(PACKAGE_VERSION_EXACT TRUE)
                \\  endif()
                \\endif()
                \\
                \\unset(_ghostty_vt_abi_first)
                \\unset(_ghostty_vt_abi_next)
                \\
                \\# Skip the pointer size check if either side doesn't know its own.
                \\if("${{CMAKE_SIZEOF_VOID_P}}" STREQUAL "")
                \\  return()
                \\endif()
                \\
                \\# Reject an install built for a different pointer size, for example
                \\# a 32-bit library found by a 64-bit project.
                \\if(NOT CMAKE_SIZEOF_VOID_P STREQUAL "{[ptr_size]d}")
                \\  math(EXPR installedBits "{[ptr_size]d} * 8")
                \\  set(PACKAGE_VERSION "${{PACKAGE_VERSION}} (${{installedBits}}bit)")
                \\  set(PACKAGE_VERSION_UNSUITABLE TRUE)
                \\endif()
                \\
            , .{
                .version = version,
                .first = abi_first,
                .next = abi_next,
                .ptr_size = ptr_size,
            }),
        );

        return .{
            .config = run.captureStdOut(.{}),
            .version = version_file,
        };
    }
};

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
        .out_path = .{ .install_prefix = "lib/ghostty-vt.xcframework" },
        .libraries = libraries[0..lib_count],
    });
}

/// Returns true if the Apple SDK for the given target is installed.
fn detectAppleSDK(
    io: std.Io,
    alloc: std.mem.Allocator,
    environ_map: *const std.process.Environ.Map,
    target: std.Target,
) bool {
    _ = std.zig.LibCInstallation.findNative(
        alloc,
        io,
        .{
            .environ_map = environ_map,
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
    // The pkg-config files go in <libdir>/pkgconfig rather than
    // share/pkgconfig. share/ is meant for files that are the same on
    // every architecture, and these name the library's directory, which
    // can differ between architectures (lib64, lib/x86_64-linux-gnu).
    // The CMake files go in <libdir>/cmake for the same reason.
    if (self.pkg_config) |pkg_config| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config,
            .lib,
            "pkgconfig/libghostty-vt.pc",
        ).step);
    }
    if (self.pkg_config_static) |pkg_config_static| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config_static,
            .lib,
            "pkgconfig/libghostty-vt-static.pc",
        ).step);
    }
    if (self.cmake) |cmake| {
        step.dependOn(&b.addInstallFileWithDir(
            cmake.config,
            .lib,
            "cmake/ghostty-vt/ghostty-vt-config.cmake",
        ).step);
        step.dependOn(&b.addInstallFileWithDir(
            cmake.version,
            .lib,
            "cmake/ghostty-vt/ghostty-vt-config-version.cmake",
        ).step);
    }
}
