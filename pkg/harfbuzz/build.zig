const std = @import("std");
const apple_sdk = @import("apple_sdk");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const coretext_enabled = b.option(bool, "enable-coretext", "Build coretext") orelse false;
    const freetype_enabled = b.option(bool, "enable-freetype", "Build freetype") orelse true;

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });
    const macos = b.dependency("macos", .{ .target = target, .optimize = optimize });

    const module = b.addModule("harfbuzz", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "freetype", .module = freetype.module("freetype") },
            .{ .name = "macos", .module = macos.module("macos") },
        },
    });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    const test_exe = b.addTest(.{
        .name = "test",
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        var it = module.import_table.iterator();
        while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        if (b.systemIntegrationOption("freetype", .{})) {
            test_exe.linkSystemLibrary2("freetype2", dynamic_link_opts);
        } else {
            test_exe.linkLibrary(freetype.artifact("freetype"));
        }
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }

    if (b.systemIntegrationOption("harfbuzz", .{})) {
        module.linkSystemLibrary("harfbuzz", dynamic_link_opts);
        test_exe.linkSystemLibrary2("harfbuzz", dynamic_link_opts);
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,

            .coretext_enabled = coretext_enabled,
            .freetype_enabled = freetype_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        test_exe.linkLibrary(lib);
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const coretext_enabled = options.coretext_enabled;
    const freetype_enabled = options.freetype_enabled;

    const freetype = b.dependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    });

    const lib = b.addStaticLibrary(.{
        .name = "harfbuzz",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    lib.linkLibCpp();

    if (target.result.os.tag.isDarwin()) {
        try apple_sdk.addPaths(b, lib);
    }

    const dynamic_link_opts = options.dynamic_link_opts;

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DHAVE_STDBOOL_H",
    });
    if (target.result.os.tag != .windows) {
        try flags.appendSlice(&.{
            "-DHAVE_UNISTD_H",
            "-DHAVE_SYS_MMAN_H",
            "-DHAVE_PTHREAD=1",
        });
    }

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // So it shows up in help
    if (freetype_enabled) {
        try flags.appendSlice(&.{
            "-DHAVE_FREETYPE=1",

            // Let's just assume a new freetype
            "-DHAVE_FT_GET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_SET_VAR_BLEND_COORDINATES=1",
            "-DHAVE_FT_DONE_MM_VAR=1",
            "-DHAVE_FT_GET_TRANSFORM=1",
        });

        if (b.systemIntegrationOption("freetype", .{})) {
            lib.linkSystemLibrary2("freetype2", dynamic_link_opts);
            module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            lib.linkLibrary(freetype.artifact("freetype"));

            if (freetype.builder.lazyDependency(
                "freetype",
                .{},
            )) |freetype_dep| {
                module.addIncludePath(freetype_dep.path("include"));
            }
        }
    }

    if (coretext_enabled) {
        try flags.appendSlice(&.{"-DHAVE_CORETEXT=1"});
        lib.linkFramework("CoreText");
        module.linkFramework("CoreText", .{});
    }

    if (b.lazyDependency("harfbuzz", .{})) |upstream| {
        lib.addIncludePath(upstream.path("src"));
        module.addIncludePath(upstream.path("src"));
        lib.addCSourceFile(.{
            .file = upstream.path("src/harfbuzz.cc"),
            .flags = flags.items,
        });
        lib.installHeadersDirectory(
            upstream.path("src"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}
