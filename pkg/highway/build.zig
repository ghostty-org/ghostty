const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const upstream_ = b.lazyDependency("highway", .{});

    const module = b.addModule("highway", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "highway",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibCpp();
    if (upstream_) |upstream| {
        lib.addIncludePath(upstream.path(""));
        module.addIncludePath(upstream.path(""));
    }

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib);
    }

    if (target.result.abi.isAndroid()) {
        const android_ndk = @import("android_ndk");
        try android_ndk.addPaths(b, lib);
    }

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.appendSlice(b.allocator, &.{
        // Avoid changing binaries based on the current time and date.
        "-Wno-builtin-macro-redefined",
        "-D__DATE__=\"redacted\"",
        "-D__TIMESTAMP__=\"redacted\"",
        "-D__TIME__=\"redacted\"",

        // Optimizations
        "-fmerge-all-constants",

        // Warnings
        "-Wall",
        "-Wextra",

        // These are not included in Wall nor Wextra:
        "-Wconversion",
        "-Wsign-conversion",
        "-Wvla",
        "-Wnon-virtual-dtor",

        "-Wfloat-overflow-conversion",
        "-Wfloat-zero-conversion",
        "-Wfor-loop-analysis",
        "-Wgnu-redeclared-enum",
        "-Winfinite-recursion",
        "-Wself-assign",
        "-Wstring-conversion",
        "-Wtautological-overlap-compare",
        "-Wthread-safety-analysis",
        "-Wundefined-func-template",

        "-fno-cxx-exceptions",
        "-fno-slp-vectorize",
        "-fno-vectorize",

        // Fixes linker issues for release builds missing ubsanitizer symbols
        "-fno-sanitize=undefined",
        "-fno-sanitize-trap=undefined",
    });

    if (target.result.os.tag == .freebsd or target.result.abi == .musl) {
        try flags.append(b.allocator, "-fPIC");
    }

    if (target.result.os.tag != .windows) {
        try flags.appendSlice(b.allocator, &.{
            "-fmath-errno",
            "-fno-exceptions",
        });
    }

    lib.addCSourceFiles(.{ .flags = flags.items, .files = &.{"bridge.cpp"} });
    if (upstream_) |upstream| {
        lib.addCSourceFiles(.{
            .root = upstream.path(""),
            .flags = flags.items,
            .files = &.{
                "hwy/abort.cc",
                "hwy/aligned_allocator.cc",
                "hwy/nanobenchmark.cc",
                "hwy/per_target.cc",
                "hwy/print.cc",
                "hwy/targets.cc",
                "hwy/timer.cc",
            },
        });
        lib.installHeadersDirectory(
            upstream.path("hwy"),
            "hwy",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    {
        const test_exe = b.addTest(.{
            .name = "test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        test_exe.linkLibrary(lib);

        var it = module.import_table.iterator();
        while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }
}
