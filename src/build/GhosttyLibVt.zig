const GhosttyLibVt = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const GhosttyZig = @import("GhosttyZig.zig");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The artifact result
artifact: *std.Build.Step.InstallArtifact,

/// The final library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,
pkg_config: std.Build.LazyPath,

pub fn initShared(
    b: *std.Build,
    zig: *const GhosttyZig,
) !GhosttyLibVt {
    const target = zig.vt.resolved_target.?;
    const lib = b.addLibrary(.{
        .name = "ghostty-vt",
        .linkage = .dynamic,
        .root_module = zig.vt_c,
        .version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 },
    });
    lib.installHeadersDirectory(
        b.path("include/ghostty"),
        "ghostty",
        .{ .include_extensions = &.{".h"} },
    );

    // Get our debug symbols
    const dsymutil: ?std.Build.LazyPath = dsymutil: {
        if (!target.result.os.tag.isDarwin()) {
            break :dsymutil null;
        }

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
    step.dependOn(&b.addInstallFileWithDir(
        self.pkg_config,
        .prefix,
        "share/pkgconfig/libghostty-vt.pc",
    ).step);
}
