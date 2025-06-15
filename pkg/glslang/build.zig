const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("glslang", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const upstream = b.dependency("glslang", .{});
    const lib = try buildGlslang(b, upstream, target, optimize);
    b.installArtifact(lib);

    module.addIncludePath(upstream.path(""));
    module.addIncludePath(b.path("override"));

    if (target.query.isNative()) {
        const test_exe = b.addTest(.{
            .name = "test",
            .root_source_file = b.path("main.zig"),
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

fn buildGlslang(
    b: *std.Build,
    upstream: *std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) !*std.Build.Step.Compile {
    const lib = b.addStaticLibrary(.{
        .name = "glslang",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    lib.addIncludePath(upstream.path(""));
    lib.addIncludePath(b.path("override"));
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    lib.addCSourceFiles(.{
        .root = upstream.path(""),
        .flags = flags.items,
        .files = &.{
            // GenericCodeGen
            "glslang/GenericCodeGen/CodeGen.cpp",
            "glslang/GenericCodeGen/Link.cpp",

            // MachineIndependent
            //"MachineIndependent/glslang.y",
            "glslang/MachineIndependent/glslang_tab.cpp",
            "glslang/MachineIndependent/attribute.cpp",
            "glslang/MachineIndependent/Constant.cpp",
            "glslang/MachineIndependent/iomapper.cpp",
            "glslang/MachineIndependent/InfoSink.cpp",
            "glslang/MachineIndependent/Initialize.cpp",
            "glslang/MachineIndependent/IntermTraverse.cpp",
            "glslang/MachineIndependent/Intermediate.cpp",
            "glslang/MachineIndependent/ParseContextBase.cpp",
            "glslang/MachineIndependent/ParseHelper.cpp",
            "glslang/MachineIndependent/PoolAlloc.cpp",
            "glslang/MachineIndependent/RemoveTree.cpp",
            "glslang/MachineIndependent/Scan.cpp",
            "glslang/MachineIndependent/ShaderLang.cpp",
            "glslang/MachineIndependent/SpirvIntrinsics.cpp",
            "glslang/MachineIndependent/SymbolTable.cpp",
            "glslang/MachineIndependent/Versions.cpp",
            "glslang/MachineIndependent/intermOut.cpp",
            "glslang/MachineIndependent/limits.cpp",
            "glslang/MachineIndependent/linkValidate.cpp",
            "glslang/MachineIndependent/parseConst.cpp",
            "glslang/MachineIndependent/reflection.cpp",
            "glslang/MachineIndependent/preprocessor/Pp.cpp",
            "glslang/MachineIndependent/preprocessor/PpAtom.cpp",
            "glslang/MachineIndependent/preprocessor/PpContext.cpp",
            "glslang/MachineIndependent/preprocessor/PpScanner.cpp",
            "glslang/MachineIndependent/preprocessor/PpTokens.cpp",
            "glslang/MachineIndependent/propagateNoContraction.cpp",

            // C Interface
            "glslang/CInterface/glslang_c_interface.cpp",

            // ResourceLimits
            "glslang/ResourceLimits/ResourceLimits.cpp",
            "glslang/ResourceLimits/resource_limits_c.cpp",

            // SPIRV
            "SPIRV/GlslangToSpv.cpp",
            "SPIRV/InReadableOrder.cpp",
            "SPIRV/Logger.cpp",
            "SPIRV/SpvBuilder.cpp",
            "SPIRV/SpvPostProcess.cpp",
            "SPIRV/doc.cpp",
            "SPIRV/disassemble.cpp",
            "SPIRV/CInterface/spirv_c_interface.cpp",
        },
    });

    if (target.result.os.tag != .windows) {
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                "glslang/OSDependent/Unix/ossource.cpp",
            },
        });
    } else {
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                "glslang/OSDependent/Windows/ossource.cpp",
            },
        });
    }

    lib.installHeadersDirectory(
        upstream.path(""),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    return lib;
}
