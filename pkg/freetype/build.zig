const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const libpng_enabled = b.option(bool, "enable-libpng", "Build libpng") orelse false;

    const module = b.addModule("freetype", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

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
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }

    module.addIncludePath(b.path(""));

    if (b.systemIntegrationOption("freetype", .{})) {
        module.linkSystemLibrary("freetype2", dynamic_link_opts);
        if (test_exe) |exe| {
            exe.linkSystemLibrary2("freetype2", dynamic_link_opts);
        }
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,

            .libpng_enabled = libpng_enabled,

            .dynamic_link_opts = dynamic_link_opts,
        });

        if (test_exe) |exe| {
            exe.linkLibrary(lib);
        }
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;

    const libpng_enabled = options.libpng_enabled;

    const lib = b.addStaticLibrary(.{
        .name = "freetype",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DFT2_BUILD_LIBRARY",

        "-DFT_CONFIG_OPTION_SYSTEM_ZLIB=1",

        "-DHAVE_UNISTD_H",
        "-DHAVE_FCNTL_H",

        "-fno-sanitize=undefined",
    });

    const dynamic_link_opts = options.dynamic_link_opts;

    // Zlib
    if (b.systemIntegrationOption("zlib", .{})) {
        lib.linkSystemLibrary2("zlib", dynamic_link_opts);
    } else {
        const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
        lib.linkLibrary(zlib_dep.artifact("z"));
    }

    // Libpng
    _ = b.systemIntegrationOption("libpng", .{}); // So it shows up in help
    if (libpng_enabled) {
        try flags.append("-DFT_CONFIG_OPTION_USE_PNG=1");

        if (b.systemIntegrationOption("libpng", .{})) {
            lib.linkSystemLibrary2("libpng", dynamic_link_opts);
        } else {
            const libpng_dep = b.dependency(
                "libpng",
                .{ .target = target, .optimize = optimize },
            );
            lib.linkLibrary(libpng_dep.artifact("png"));
        }
    }

    if (b.lazyDependency("freetype", .{})) |upstream| {
        lib.addIncludePath(upstream.path("include"));
        module.addIncludePath(upstream.path("include"));
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        switch (target.result.os.tag) {
            .linux => lib.addCSourceFile(.{
                .file = upstream.path("builds/unix/ftsystem.c"),
                .flags = flags.items,
            }),
            .windows => lib.addCSourceFile(.{
                .file = upstream.path("builds/windows/ftsystem.c"),
                .flags = flags.items,
            }),
            else => lib.addCSourceFile(.{
                .file = upstream.path("src/base/ftsystem.c"),
                .flags = flags.items,
            }),
        }
        switch (target.result.os.tag) {
            .windows => {
                lib.addCSourceFile(.{
                    .file = upstream.path("builds/windows/ftdebug.c"),
                    .flags = flags.items,
                });
                lib.addWin32ResourceFile(.{
                    .file = upstream.path("src/base/ftver.rc"),
                });
            },
            else => lib.addCSourceFile(.{
                .file = upstream.path("src/base/ftdebug.c"),
                .flags = flags.items,
            }),
        }

        lib.installHeader(b.path("freetype-zig.h"), "freetype-zig.h");
        lib.installHeadersDirectory(
            upstream.path("include"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    return lib;
}

const srcs: []const []const u8 = &.{
    "src/autofit/autofit.c",
    "src/base/ftbase.c",
    "src/base/ftbbox.c",
    "src/base/ftbdf.c",
    "src/base/ftbitmap.c",
    "src/base/ftcid.c",
    "src/base/ftfstype.c",
    "src/base/ftgasp.c",
    "src/base/ftglyph.c",
    "src/base/ftgxval.c",
    "src/base/ftinit.c",
    "src/base/ftmm.c",
    "src/base/ftotval.c",
    "src/base/ftpatent.c",
    "src/base/ftpfr.c",
    "src/base/ftstroke.c",
    "src/base/ftsynth.c",
    "src/base/fttype1.c",
    "src/base/ftwinfnt.c",
    "src/bdf/bdf.c",
    "src/bzip2/ftbzip2.c",
    "src/cache/ftcache.c",
    "src/cff/cff.c",
    "src/cid/type1cid.c",
    "src/gzip/ftgzip.c",
    "src/lzw/ftlzw.c",
    "src/pcf/pcf.c",
    "src/pfr/pfr.c",
    "src/psaux/psaux.c",
    "src/pshinter/pshinter.c",
    "src/psnames/psnames.c",
    "src/raster/raster.c",
    "src/sdf/sdf.c",
    "src/sfnt/sfnt.c",
    "src/smooth/smooth.c",
    "src/svg/svg.c",
    "src/truetype/truetype.c",
    "src/type1/type1.c",
    "src/type42/type42.c",
    "src/winfonts/winfnt.c",
};
