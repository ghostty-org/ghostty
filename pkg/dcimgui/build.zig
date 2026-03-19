const std = @import("std");
const NativeTargetInfo = std.zig.system.NativeTargetInfo;

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const freetype = b.option(bool, "freetype", "Use Freetype") orelse false;
    const backend_opengl3 = b.option(bool, "backend-opengl3", "OpenGL3 backend") orelse false;
    const backend_metal = b.option(bool, "backend-metal", "Metal backend") orelse false;
    const backend_osx = b.option(bool, "backend-osx", "OSX backend") orelse false;

    // Build options
    const options = b.addOptions();
    options.addOption(bool, "freetype", freetype);
    options.addOption(bool, "backend_opengl3", backend_opengl3);
    options.addOption(bool, "backend_metal", backend_metal);
    options.addOption(bool, "backend_osx", backend_osx);

    // Main static lib
    const lib = b.addLibrary(.{
        .name = "dcimgui",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    lib.linkLibCpp();
    b.installArtifact(lib);

    // Zig module
    const mod = b.addModule("dcimgui", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    mod.addOptions("build_options", options);
    mod.linkLibrary(lib);

    // We need to add proper Apple SDKs to find stdlib headers
    if (target.result.os.tag.isDarwin()) {
        if (!target.query.isNative()) {
            try @import("apple_sdk").addPaths(b, lib);
        }
    }

    // Flags for C compilation, common to all.
    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        "-DIMGUI_HAS_DOCK=1",
        "-DIMGUI_USE_WCHAR32=1",
        "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
    });
    if (freetype) try flags.appendSlice(b.allocator, &.{
        "-DIMGUI_ENABLE_FREETYPE=1",
    });
    if (backend_opengl3) try flags.appendSlice(b.allocator, &.{
        "-DZIGPKG_IMGUI_ENABLE_OPENGL3=1",
    });
    if (target.result.os.tag == .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-DIMGUI_IMPL_API=extern\t\"C\"\t__declspec(dllexport)",
        });
    } else {
        try flags.appendSlice(b.allocator, &.{
            "-DIMGUI_IMPL_API=extern\t\"C\"",
        });
    }
    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try flags.append(b.allocator, "-fPIC");
    }

    // Add the core Dear Imgui source files
    if (b.lazyDependency("imgui", .{})) |upstream| {
        lib.addIncludePath(upstream.path(""));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{
                "imgui_demo.cpp",
                "imgui_draw.cpp",
                "imgui_tables.cpp",
                "imgui_widgets.cpp",
                "imgui.cpp",
            },
            .flags = flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );

        if (freetype) {
            lib.addCSourceFile(.{
                .file = upstream.path("misc/freetype/imgui_freetype.cpp"),
                .flags = flags.items,
            });

            if (b.systemIntegrationOption("freetype", .{})) {
                lib.linkSystemLibrary2("freetype2", dynamic_link_opts);
            } else {
                const freetype_dep = b.dependency("freetype", .{
                    .target = target,
                    .optimize = optimize,
                    .@"enable-libpng" = true,
                });
                lib.linkLibrary(freetype_dep.artifact("freetype"));
                if (freetype_dep.builder.lazyDependency(
                    "freetype",
                    .{},
                )) |freetype_upstream| {
                    mod.addIncludePath(freetype_upstream.path("include"));
                }
            }
        }

        if (backend_metal) {
            lib.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_metal.mm"},
                .flags = flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_metal.h"} },
            );
        }
        if (backend_osx) {
            lib.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_osx.mm"},
                .flags = flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_osx.h"} },
            );
        }
        if (backend_opengl3) {
            lib.addCSourceFiles(.{
                .root = upstream.path("backends"),
                .files = &.{"imgui_impl_opengl3.cpp"},
                .flags = flags.items,
            });
            lib.installHeadersDirectory(
                upstream.path("backends"),
                "",
                .{ .include_extensions = &.{"imgui_impl_opengl3.h"} },
            );
        }
    }

    // Add the C bindings
    if (b.lazyDependency("bindings", .{})) |upstream| {
        lib.addIncludePath(upstream.path(""));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = &.{
                "dcimgui.cpp",
                "dcimgui_internal.cpp",
            },
            .flags = flags.items,
        });
        lib.addCSourceFiles(.{
            .root = b.path(""),
            .files = &.{"ext.cpp"},
            .flags = flags.items,
        });

        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    const test_exe = b.addTest(.{
        .name = "test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    test_exe.root_module.addOptions("build_options", options);
    test_exe.linkLibrary(lib);
    const tests_run = b.addRunArtifact(test_exe);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&tests_run.step);
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
