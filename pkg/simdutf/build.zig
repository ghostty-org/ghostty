const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("simdutf", .{
        .root_source_file = .{ .path = "main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addStaticLibrary(.{
        .name = "simdutf",
        .target = target,
        .optimize = optimize,
    });
    lib.linkLibCpp();
    lib.addIncludePath(.{ .path = "vendor" });
    module.addIncludePath(.{ .path = "vendor" });

    if (target.result.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, &lib.root_module);
        try apple_sdk.addPaths(b, module);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.appendSlice(&.{});

    lib.addCSourceFiles(.{
        .flags = flags.items,
        .files = &.{
            "vendor/simdutf.cpp",
        },
    });
    lib.installHeadersDirectoryOptions(.{
        .source_dir = .{ .path = "vendor" },
        .install_dir = .header,
        .install_subdir = "",
        .include_extensions = &.{".h"},
    });

    b.installArtifact(lib);

    {
        const test_exe = b.addTest(.{
            .name = "test",
            .root_source_file = .{ .path = "main.zig" },
            .target = target,
            .optimize = optimize,
        });
        test_exe.linkLibrary(lib);

        var it = module.import_table.iterator();
        while (it.next()) |entry| test_exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        const tests_run = b.addRunArtifact(test_exe);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }
}
