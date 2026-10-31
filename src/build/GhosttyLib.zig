const GhosttyLib = @This();

const std = @import("std");
const builtin = @import("builtin");
const RunStep = std.Build.Step.Run;
const CombineArchivesStep = @import("CombineArchivesStep.zig");
const Config = @import("Config.zig");
const LibsystemOverrideStep = @import("LibsystemOverrideStep.zig");
const SharedDeps = @import("SharedDeps.zig");
const WindowsCrt = @import("WindowsCrt.zig");
const LipoStep = @import("LipoStep.zig");
const GhosttyPkgConfig = @import("GhosttyPkgConfig.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The final static library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,
pkg_config_static: ?std.Build.LazyPath,

pub fn initStatic(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
            .link_libc = true,
        }),

        // Fails on self-hosted x86_64 on macOS
        .use_llvm = true,
    });

    // These must be bundled since we're compiling into a static lib.
    // Otherwise, you get undefined symbol errors.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    if (deps.config.target.result.os.tag == .windows) {
        // Zig's ubsan emits /exclude-symbols linker directives that
        // are incompatible with the MSVC linker (LNK4229).
        lib.bundle_ubsan_rt = false;
    }

    // Add our dependencies. Get the list of all static deps so we can
    // build a combined archive.
    var lib_list = try deps.add(lib);
    try lib_list.append(b.allocator, lib.getEmittedBin());

    // Combine all archives into a single fat static library so
    // consumers only need to link one file.
    const combined = CombineArchivesStep.create(b, deps.config.target, "ghostty-internal", lib_list.items);
    combined.step.dependOn(&lib.step);

    // On Darwin, prefer libSystem's libc/libm over the bundled
    // compiler-rt for consumers of this archive. See
    // libsystem_override.sh for details. This is a no-op elsewhere.
    const override = LibsystemOverrideStep.create(
        b,
        deps.config.target,
        combined.output,
        "libghostty-internal.a",
    );

    return .{
        .step = override.step orelse combined.step,
        .output = override.output,

        // Static libraries cannot have dSYMs because they aren't linked.
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}

pub fn initShared(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addLibrary(.{
        .name = "ghostty",
        .linkage = .dynamic,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.omitFramePointer(),
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),

        // Fails on self-hosted x86_64
        .use_llvm = true,
    });
    _ = try deps.add(lib);

    // Building an MSVC DLL requires the full CRT library chain.
    if (deps.config.target.result.os.tag == .windows and
        deps.config.target.result.abi == .msvc)
    {
        try WindowsCrt.link(b, lib);
    }

    // Get our debug symbols
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (!deps.config.target.result.os.tag.isDarwin()) {
            break :dsymutil null;
        }

        const dsymutil = RunStep.create(b, "dsymutil");
        dsymutil.addArgs(&.{"dsymutil"});
        dsymutil.addFileArg(lib.getEmittedBin());
        dsymutil.addArgs(&.{"-o"});
        const output = dsymutil.addOutputFileArg("libghostty.dSYM");
        break :dsymutil output;
    };

    // pkg-config
    //
    // pkg-config's --static only expands Libs.private / Requires.private;
    // it doesn't rewrite Libs: into an archive-only reference when both
    // shared and static libraries are installed. Install a dedicated
    // static module so consumers can request the archive explicitly.
    const pcs = try pkgConfigFiles(b, deps);

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = pcs.shared,
        .pkg_config_static = pcs.static,
    };
}

pub fn initMacOSUniversal(
    b: *std.Build,
    original_deps: *const SharedDeps,
) !GhosttyLib {
    const aarch64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .aarch64),
    ));
    const x86_64 = try initStatic(b, &try original_deps.retarget(
        b,
        Config.genericMacOSTarget(b, .x86_64),
    ));

    const universal = LipoStep.create(b, .{
        .name = "ghostty",
        .out_name = "ghostty-internal.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });

    return .{
        .step = universal.step,
        .output = universal.output,

        // You can't run dsymutil on a universal binary, you have to
        // do it on the individual binaries.
        .dsym = null,
        .pkg_config = null,
        .pkg_config_static = null,
    };
}

pub fn install(self: *const GhosttyLib, name: []const u8) void {
    const b = self.step.owner;
    const step = b.getInstallStep();
    const lib_install = b.addInstallLibFile(self.output, name);
    step.dependOn(&lib_install.step);

    if (self.pkg_config) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/ghostty-internal.pc",
        ).step);
    }
    if (self.pkg_config_static) |pc| {
        step.dependOn(&b.addInstallFileWithDir(
            pc,
            .prefix,
            "share/pkgconfig/ghostty-internal-static.pc",
        ).step);
    }
}

pub fn installHeader(self: *const GhosttyLib) void {
    const b = self.step.owner;
    const header_install = b.addInstallHeaderFile(
        b.path("include/ghostty.h"),
        "ghostty.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
}

const PkgConfigFiles = struct {
    shared: std.Build.LazyPath,
    static: std.Build.LazyPath,
};

fn pkgConfigFiles(
    b: *std.Build,
    deps: *const SharedDeps,
) !PkgConfigFiles {
    const os_tag = deps.config.target.result.os.tag;

    const pkg_config: GhosttyPkgConfig = try .init(b, .{
        .name = "ghostty-internal",
        .name_static = "ghostty-internal-static",
        .description = "Ghostty internal library (not for external use)",
        .description_static = "Ghostty internal library, static (not for external use)",
        .version = deps.config.version,
        .libs = &.{b.fmt("${{libdir}}/{s}", .{sharedLibraryName(os_tag)})},
        .libs_static = &.{b.fmt("${{libdir}}/{s}", .{staticLibraryName(os_tag)})},
    });

    return .{
        .shared = pkg_config.getSharedFile(),
        .static = pkg_config.getStaticFile(),
    };
}

fn sharedLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-internal.dll"
    else
        "ghostty-internal.so";
}

fn staticLibraryName(os_tag: std.Target.Os.Tag) []const u8 {
    return if (os_tag == .windows)
        "ghostty-internal-static.lib"
    else
        "ghostty-internal.a";
}
