const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("wuffs", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.linkLibC();

    var flags = std.ArrayList([]const u8).init(b.allocator);
    defer flags.deinit();
    try flags.append("-DWUFFS_IMPLEMENTATION");
    inline for (@import("src/c.zig").defines) |key| {
        try flags.append("-D" ++ key);
    }

    if (b.lazyDependency("wuffs", .{})) |wuffs_dep| {
        module.addIncludePath(wuffs_dep.path("release/c"));
        module.addCSourceFile(.{
            .file = wuffs_dep.path("release/c/wuffs-v0.4.c"),
            .flags = flags.items,
        });

        unit_tests.addIncludePath(wuffs_dep.path("release/c"));
        unit_tests.addCSourceFile(.{
            .file = wuffs_dep.path("release/c/wuffs-v0.4.c"),
            .flags = flags.items,
        });
    }

    if (b.lazyDependency("pixels", .{})) |pixels_dep| {
        inline for (.{ "000000", "FFFFFF" }) |color| {
            inline for (.{ "gif", "jpg", "png", "ppm" }) |extension| {
                const filename = std.fmt.comptimePrint(
                    "1x1#{s}.{s}",
                    .{ color, extension },
                );
                unit_tests.root_module.addAnonymousImport(filename, .{
                    .root_source_file = pixels_dep.path(filename),
                });
            }
        }
    }

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
