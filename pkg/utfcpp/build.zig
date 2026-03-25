const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addLibrary(.{
        .name = "utfcpp",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
        }),
        .linkage = .static,
    });
    lib.linkLibC();
    // On MSVC, we must not use linkLibCpp because Zig unconditionally
    // passes -nostdinc++ and then adds its bundled libc++/libc++abi
    // include paths, which conflict with MSVC's own C++ runtime headers.
    // The MSVC SDK include directories (added via linkLibC) contain
    // both C and C++ headers, so linkLibCpp is not needed.
    if (target.result.abi != .msvc) {
        lib.linkLibCpp();
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

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{"empty.cc"},
    });

    if (b.lazyDependency("utfcpp", .{})) |upstream| {
        lib.addIncludePath(upstream.path(""));
        lib.installHeadersDirectory(
            upstream.path("source"),
            "",
            .{ .include_extensions = &.{".h"} },
        );
    }

    b.installArtifact(lib);

    // {
    //     const test_exe = b.addTest(.{
    //         .name = "test",
    //         .root_source_file = .{ .path = "main.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     test_exe.linkLibrary(lib);
    //
    //     var it = module.import_table.iterator();
    //     while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
    //     const tests_run = b.addRunArtifact(test_exe);
    //     const test_step = b.step("test", "Run tests");
    //     test_step.dependOn(&tests_run.step);
    // }
}
