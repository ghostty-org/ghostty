const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "png",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
        .linkage = .static,
    });
    if (target.result.os.tag == .linux) {
        lib.root_module.linkSystemLibrary("m", .{});
    }
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    if (b.systemIntegrationOption("zlib", .{})) {
        lib.root_module.linkSystemLibrary("zlib", dynamic_link_opts);
    } else {
        if (b.lazyDependency(
            "zlib",
            .{ .target = target, .optimize = optimize },
        )) |zlib_dep| {
            lib.root_module.linkLibrary(zlib_dep.artifact("z"));
            lib.root_module.addIncludePath(b.path(""));
        }

        if (b.lazyDependency("libpng", .{})) |upstream| {
            lib.root_module.addIncludePath(upstream.path(""));
        }
    }

    if (b.lazyDependency("libpng", .{})) |upstream| {
        var flags: std.ArrayList([]const u8) = .empty;
        defer flags.deinit(b.allocator);
        try flags.appendSlice(b.allocator, &.{
            "-DPNG_ARM_NEON_OPT=0",
            "-DPNG_POWERPC_VSX_OPT=0",
            "-DPNG_INTEL_SSE_OPT=0",
            "-DPNG_MIPS_MSA_OPT=0",
        });

        lib.root_module.addCSourceFiles(.{
            .root = upstream.path(""),
            .files = srcs,
            .flags = flags.items,
        });

        lib.installHeader(b.path("pnglibconf.h"), "pnglibconf.h");
        lib.installHeadersDirectory(
            upstream.path(""),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);
}

const srcs: []const []const u8 = &.{
    "png.c",
    "pngerror.c",
    "pngget.c",
    "pngmem.c",
    "pngpread.c",
    "pngread.c",
    "pngrio.c",
    "pngrtran.c",
    "pngrutil.c",
    "pngset.c",
    "pngtrans.c",
    "pngwio.c",
    "pngwrite.c",
    "pngwtran.c",
    "pngwutil.c",
};
