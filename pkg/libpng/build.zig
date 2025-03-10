const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream = b.dependency("libpng", .{});

    const lib = b.addStaticLibrary(.{
        .name = "png",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibC();
    if (target.result.os.tag == .linux) {
        lib.linkSystemLibrary("m");
    }
    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib.root_module);
    }

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    if (b.systemIntegrationOption("zlib", .{})) {
        lib.linkSystemLibrary2("zlib", dynamic_link_opts);
    } else {
        const zlib_dep = b.dependency("zlib", .{ .target = target, .optimize = optimize });
        lib.linkLibrary(zlib_dep.artifact("z"));
        lib.addIncludePath(upstream.path(""));
        lib.addIncludePath(b.path(""));
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
        "-DPNG_ARM_NEON_OPT=0",
        "-DPNG_POWERPC_VSX_OPT=0",
        "-DPNG_INTEL_SSE_OPT=0",
        "-DPNG_MIPS_MSA_OPT=0",
    });

    lib.addCSourceFiles(.{
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
