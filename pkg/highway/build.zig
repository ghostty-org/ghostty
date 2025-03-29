const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("highway", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{
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
    });
    if (target.result.os.tag != .windows) {
        try flags.appendSlice(&.{
            "-fmath-errno",
            "-fno-exceptions",
        });
    }
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
        var it = module.import_table.iterator();
        while (it.next()) |entry| test_exe.?.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);

        // Uncomment this if we're debugging tests
        // b.installArtifact(test_exe.?);
    }

    module.addCSourceFiles(
        .{ .flags = flags.items, .files = &.{"bridge.cpp"} },
    );

    if (b.systemIntegrationOption("highway", .{})) {
        module.linkSystemLibrary("libhwy", dynamic_link_opts);
    } else {
        const lib = try buildLib(b, module, .{
            .target = target,
            .optimize = optimize,
            .flags = flags,
        });
        if (test_exe) |exe| {
            exe.linkLibrary(lib);
        }
    }
}

fn buildLib(b: *std.Build, module: *std.Build.Module, options: anytype) !*std.Build.Step.Compile {
    const target = options.target;
    const optimize = options.optimize;
    const flags = options.flags;

    const lib = b.addStaticLibrary(.{
        .name = "highway",
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const upstream = b.lazyDependency("highway", .{}) orelse
        return lib;

    lib.linkLibCpp();
    lib.addIncludePath(upstream.path(""));
    module.addIncludePath(upstream.path(""));

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, lib.root_module);
        try apple_sdk.addPaths(b, module);
    }

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

    return lib;
}
