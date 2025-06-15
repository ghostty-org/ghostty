const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("cimgui", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const imgui = b.dependency("imgui", .{});
    const lib = b.addStaticLibrary(.{
        .name = "cimgui",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    if (target.result.os.tag == .windows) {
        lib.linkSystemLibrary("imm32");
    }

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    if (b.systemIntegrationOption("freetype", .{})) {
        lib.linkSystemLibrary2("freetype2", dynamic_link_opts);
    } else {
        const freetype = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        });
        lib.linkLibrary(freetype.artifact("freetype"));

        if (freetype.builder.lazyDependency(
            "freetype",
            .{},
        )) |freetype_dep| {
            module.addIncludePath(freetype_dep.path("include"));
        }
    }

    lib.addIncludePath(imgui.path(""));
    module.addIncludePath(b.path("vendor"));

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DCIMGUI_FREETYPE=1",
        "-DIMGUI_USE_WCHAR32=1",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
    });
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(&.{
            "-DIMGUI_IMPL_API=extern\t\"C\"\t__declspec(dllexport)",
        });
    } else {
        try flags.appendSlice(&.{
            "-DIMGUI_IMPL_API=extern\t\"C\"",
        });
    }

    lib.addCSourceFile(.{ .file = b.path("vendor/cimgui.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("imgui.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("imgui_draw.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("imgui_demo.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("imgui_widgets.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("imgui_tables.cpp"), .flags = flags.items });
    lib.addCSourceFile(.{ .file = imgui.path("misc/freetype/imgui_freetype.cpp"), .flags = flags.items });

    lib.addCSourceFile(.{
        .file = imgui.path("backends/imgui_impl_opengl3.cpp"),
        .flags = flags.items,
    });

    if (target.result.os.tag.isDarwin()) {
        if (!target.query.isNative()) {
            try @import("apple_sdk").addPaths(b, lib);
        }
        lib.addCSourceFile(.{
            .file = imgui.path("backends/imgui_impl_metal.mm"),
            .flags = flags.items,
        });
        if (target.result.os.tag == .macos) {
            lib.addCSourceFile(.{
                .file = imgui.path("backends/imgui_impl_osx.mm"),
                .flags = flags.items,
            });
        }
    }

    lib.installHeadersDirectory(
        b.path("vendor"),
        "",
        .{ .include_extensions = &.{".h"} },
    );

    b.installArtifact(lib);

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
}
