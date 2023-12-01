const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("spirv_cross", .{ .source_file = .{ .path = "main.zig" } });

    const upstream = b.dependency("spirv_cross", .{});
    const lib = try buildSpirvCross(b, upstream, target, optimize);
    b.installArtifact(lib);

    {
        const test_exe = b.addTest(.{
            .name = "test",
            .root_source_file = .{ .path = "main.zig" },
            .target = target,
            .optimize = optimize,
        });
        test_exe.linkLibrary(lib);
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);

        // Uncomment this if we're debugging tests
        // b.installArtifact(test_exe);
    }
}

fn buildSpirvCross(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.zig.CrossTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "spirv_cross",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    //lib.addIncludePath(upstream.path(""));
    //lib.addIncludePath(.{ .path = "override" });

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DSPIRV_CROSS_C_API_GLSL=1",
        "-DSPIRV_CROSS_C_API_MSL=1",

        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    lib.addCSourceFiles(.{
        .dependency = upstream,
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

    lib.installHeadersDirectoryOptions(.{
        .source_dir = upstream.path(""),
        .install_dir = .header,
        .install_subdir = "",
        .include_extensions = &.{".h"},
    });

    return lib;
}
