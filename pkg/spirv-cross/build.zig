const std = @import("std");
const translate_c = @import("translate_c");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("spirv_cross", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_module = module,
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        // b.installArtifact(test_exe.?);
    }

    const lib: union(enum) {
        system,
        static: *std.Build.Step.Compile,
    } = if (b.systemIntegrationOption("spirv-cross", .{}))
        .system
    else
        .{ .static = try buildSpirvCross(b, module, target, optimize) };

    try translate_c.addImportToModule(b, "spirv_cross_c", module, .{
        .source = .{ .includes = .{
            .files = &.{.{ .path = "spirv_cross_c.h" }},
        } },
        .target = target,
        .optimize = optimize,
        .link_system_libs = if (lib == .system) &.{"spirv-cross-c-shared"} else &.{},
        .link_libs = if (lib == .static) &.{lib.static} else &.{},
    });
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
            .link_libc = true,
            // On MSVC, we must not use linkLibCpp because Zig unconditionally
            // passes -nostdinc++ and then adds its bundled libc++/libc++abi
            // include paths, which conflict with MSVC's own C++ runtime
            // headers. The MSVC SDK include directories (added via linkLibC)
            // contain both C and C++ headers, so linkLibCpp is not needed.
            .link_libcpp = target.result.abi != .msvc,
        }),
        .linkage = .static,
    });
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

    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try flags.append(b.allocator, "-fPIC");
    }

    if (b.lazyDependency("spirv_cross", .{})) |upstream| {
        lib.root_module.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
        lib.root_module.addCSourceFiles(.{
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

    b.installArtifact(lib);

    return lib;
}
