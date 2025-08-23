const GhosttyLib = @This();

const std = @import("std");
const RunStep = std.Build.Step.Run;
const Config = @import("Config.zig");
const SharedDeps = @import("SharedDeps.zig");
const LibtoolStep = @import("LibtoolStep.zig");
const LipoStep = @import("LipoStep.zig");

/// The step that generates the file.
step: *std.Build.Step,

/// The final static library file
output: std.Build.LazyPath,
dsym: ?std.Build.LazyPath,

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
            .omit_frame_pointer = deps.config.strip,
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),
        .linkage = .static,
    });
    lib.linkLibC();

    // These must be bundled since we're compiling into a static lib.
    // Otherwise, you get undefined symbol errors.
    lib.bundle_compiler_rt = true;
    lib.bundle_ubsan_rt = true;

    // Add our dependencies. Get the list of all static deps so we can
    // build a combined archive if necessary.
    var lib_list = try deps.add(lib);
    try lib_list.append(lib.getEmittedBin());

    if (!deps.config.target.result.os.tag.isDarwin()) return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .dsym = null,
    };

    // Create a static lib that contains all our dependencies.
    const libtool = LibtoolStep.create(b, .{
        .name = "ghostty",
        .out_name = "libghostty-fat.a",
        .sources = lib_list.items,
    });
    libtool.step.dependOn(&lib.step);

    return .{
        .step = libtool.step,
        .output = libtool.output,

        // Static libraries cannot have dSYMs because they aren't linked.
        .dsym = null,
    };
}

pub fn initShared(
    b: *std.Build,
    deps: *const SharedDeps,
) !GhosttyLib {
    const lib = b.addSharedLibrary(.{
        .name = "ghostty",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_c.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
            .omit_frame_pointer = deps.config.strip,
            .unwind_tables = if (deps.config.strip) .none else .sync,
        }),
    });
    _ = try deps.add(lib);

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

    return .{
        .step = &lib.step,
        .output = lib.getEmittedBin(),
        .dsym = dsymutil,
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
        .out_name = "libghostty.a",
        .input_a = aarch64.output,
        .input_b = x86_64.output,
    });

    return .{
        .step = universal.step,
        .output = universal.output,

        // You can't run dsymutil on a universal binary, you have to
        // do it on the individual binaries.
        .dsym = null,
    };
}

pub fn install(self: *const GhosttyLib, name: []const u8) void {
    const b = self.step.owner;
    const lib_install = b.addInstallLibFile(self.output, name);
    b.getInstallStep().dependOn(&lib_install.step);
}

pub fn installHeader(self: *const GhosttyLib) void {
    const b = self.step.owner;
    const header_install = b.addInstallHeaderFile(
        b.path("include/ghostty.h"),
        "ghostty.h",
    );
    b.getInstallStep().dependOn(&header_install.step);
}
