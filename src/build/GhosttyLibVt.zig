const GhosttyLibVt = @This();

const std = @import("std");
const assert = std.debug.assert;
const RunStep = std.Build.Step.Run;
const GhosttyZig = @import("GhosttyZig.zig");
const SharedDeps = @import("SharedDeps.zig");

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

    if (lib.rootModuleTarget().os.tag.isDarwin()) {
        // Self-hosted x86_64 doesn't work for darwin. It may not work
        // for other platforms too but definitely darwin.
        lib.use_llvm = true;

        // This is required for codesign and dynamic linking to work.
        lib.headerpad_max_install_names = true;
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
            \\Libs.private: {s}
            \\Requires.private: {s}
        , .{ b.install_prefix, libsPrivate(zig), requiresPrivate(b) }));
    };

    // For static libraries with vendored SIMD dependencies, combine
    // all archives into a single fat archive so consumers only need
    // to link one file. Skip on Windows where ar/libtool aren't available.
    if (kind == .static and
        zig.simd_libs.items.len > 0 and
        target.result.os.tag != .windows)
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
            .pkg_config = pc,
        };
    }

    return .{
        .step = &lib.step,
        .artifact = &b.addInstallArtifact(lib, .{}).step,
        .kind = kind,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
        .pkg_config = pc,
    };
}

/// Combine multiple static archives into a single fat archive.
/// Uses ar MRI scripts to combine archives directly without extracting.
fn combineArchives(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    sources: []const std.Build.LazyPath,
) struct { step: *std.Build.Step, output: std.Build.LazyPath } {
    _ = target;

    // On non-Darwin, use an MRI script with ar -M to combine archives
    // directly without extracting. This avoids issues with ar x
    // producing full-path member names and read-only permissions.
    const run = RunStep.create(b, "combine-archives ghostty-vt");
    run.addArgs(&.{
        "/bin/sh", "-c",
        \\set -e
        \\out="$1"; shift
        \\script="CREATE $out"
        \\for a in "$@"; do
        \\  script="$script
        \\ADDLIB $a"
        \\done
        \\script="$script
        \\SAVE
        \\END"
        \\echo "$script" | ar -M
        ,
        "_",
    });
    const output = run.addOutputFileArg("libghostty-vt.a");
    for (sources) |source| run.addFileArg(source);

    return .{ .step = &run.step, .output = output };
}

/// Returns the Libs.private value for the pkg-config file.
/// This includes the C++ standard library needed by SIMD code.
///
/// Zig compiles C++ code with LLVM's libc++ (not GNU libstdc++),
/// so consumers linking the static library need a libc++-compatible
/// toolchain: `zig cc`, `clang`, or GCC with `-lc++` installed.
fn libsPrivate(
    zig: *const GhosttyZig,
) []const u8 {
    return if (zig.vt_c.link_libcpp orelse false) "-lc++" else "";
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
}
