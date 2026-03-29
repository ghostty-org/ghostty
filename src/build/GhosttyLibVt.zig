const GhosttyLibVt = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const RunStep = std.Build.Step.Run;
const GhosttyZig = @import("GhosttyZig.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The artifact result
artifact: *std.Build.Step.InstallArtifact,

/// The kind of library
kind: Kind,

/// The final library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: ?std.Build.LazyPath,

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
        .version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 },
    });

    // Allow exported symbols to actually be exported.
    exe.rdynamic = true;

    // There is no entrypoint for this wasm module.
    exe.entry = .disabled;

    // Export the function table so the host can add callback entries.
    exe.export_table = true;

    return .{
        .step = &exe.step,
        .artifact = b.addInstallArtifact(exe, .{}),
        .kind = .wasm,
        .output = exe.getEmittedBin(),
        .dsym = null,
        .pkg_config = null,
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
        .version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 },
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
    const pc: std.Build.LazyPath = pc: {
        const wf = b.addWriteFiles();
        break :pc wf.add("libghostty-vt.pc", b.fmt(
            \\prefix={s}
            \\includedir=${{prefix}}/include
            \\libdir=${{prefix}}/lib
            \\
            \\Name: libghostty-vt
            \\URL: https://github.com/ghostty-org/ghostty
            \\Description: Ghostty VT library
            \\Version: 0.1.0
            \\Cflags: -I${{includedir}}
            \\Libs: -L${{libdir}} -lghostty-vt
        , .{b.install_prefix}));
    };

    return .{
        .step = &lib.step,
        .artifact = b.addInstallArtifact(lib, .{}),
        .kind = kind,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = pc,
    };
}

pub fn install(
    self: *const GhosttyLibVt,
    step: *std.Build.Step,
) void {
    const b = step.owner;
    step.dependOn(&self.artifact.step);
    if (self.pkg_config) |pkg_config| {
        step.dependOn(&b.addInstallFileWithDir(
            pkg_config,
            .prefix,
            "share/pkgconfig/libghostty-vt.pc",
        ).step);
    }
}
