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
    const target = zig.vt.resolved_target.?;

    // Prefer Apple's linker for final Darwin dylibs when its toolchain is
    // available. Besides producing the platform load commands expected by
    // Apple distribution, this lets the static archive's libSystem symbol
    // override take effect. Cross-compiled macOS dylibs continue through Zig.
    if (@import("apple_sdk").nativeLink.available(target)) {
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
