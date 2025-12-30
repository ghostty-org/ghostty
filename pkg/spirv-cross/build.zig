const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("spirv_cross", .{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        // b.installArtifact(test_exe.?);
    }
    if (b.systemIntegrationOption("spirv-cross", .{})) {
        module.linkSystemLibrary("spirv-cross-c-shared", dynamic_link_opts);
        if (test_exe) |exe| {
            exe.linkSystemLibrary2("spirv-cross-c-shared", dynamic_link_opts);
        }
    } else {
        const lib = try buildSpirvCross(b, module, target, optimize);
        b.installArtifact(lib);
        if (test_exe) |exe| exe.linkLibrary(lib);
    }
}

fn buildSpirvCross(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addLibrary(.{
        .name = "spirv_cross",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DSPIRV_CROSS_C_API_GLSL=1",
        "-DSPIRV_CROSS_C_API_MSL=1",

        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    if (target.result.os.tag == .freebsd) {
        try flags.append(b.allocator, "-fPIC");
    }

    if (b.lazyDependency("spirv_cross", .{})) |upstream| {
        lib.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                // Core
                "spirv_cross.cpp",
                "spirv_parser.cpp",
                "spirv_cross_parsed_ir.cpp",
                "spirv_cfg.cpp",

                // C
                "spirv_cross_c.cpp",

                // GLSL
                "spirv_glsl.cpp",

                // MSL
                "spirv_msl.cpp",
            },
        });

        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    return lib;
}
