const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const wuffs = b.dependency("wuffs", .{});

    const module = b.addModule("wuffs", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    if (target.result.os.tag.isDarwin()) {
        const apple_sdk = @import("apple_sdk");
        try apple_sdk.addPaths(b, module);
    }

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.append("-DWUFFS_IMPLEMENTATION");
    inline for (@import("src/c.zig").defines) |key| {
        try flags.append("-D" ++ key);
    }

    module.addIncludePath(wuffs.path("release/c"));
    module.addCSourceFile(.{
        .file = wuffs.path("release/c/wuffs-v0.4.c"),
        .flags = flags.items,
    });

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    unit_tests.linkLibC();
    unit_tests.addIncludePath(wuffs.path("release/c"));
    unit_tests.addCSourceFile(.{
        .file = wuffs.path("release/c/wuffs-v0.4.c"),
        .flags = flags.items,
    });

    const pixels = b.dependency("pixels", .{});

    inline for (.{ "000000", "FFFFFF" }) |color| {
        inline for (.{ "gif", "jpg", "png", "ppm" }) |extension| {
            const filename = std.fmt.comptimePrint("1x1#{s}.{s}", .{ color, extension });
            unit_tests.root_module.addAnonymousImport(
                filename,
                .{
                    .root_source_file = pixels.path(filename),
                },
            );
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
