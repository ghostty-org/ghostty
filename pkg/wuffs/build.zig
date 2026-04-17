const std = @import("std");

/// All the C macros defined so that the header matches the build.
const defines: []const []const u8 = &.{
    "WUFFS_CONFIG__MODULES",
    "WUFFS_CONFIG__MODULE__AUX__BASE",
    "WUFFS_CONFIG__MODULE__AUX__IMAGE",
    "WUFFS_CONFIG__MODULE__BASE",
    "WUFFS_CONFIG__MODULE__ADLER32",
    "WUFFS_CONFIG__MODULE__CRC32",
    "WUFFS_CONFIG__MODULE__DEFLATE",
    "WUFFS_CONFIG__MODULE__JPEG",
    "WUFFS_CONFIG__MODULE__PNG",
    "WUFFS_CONFIG__MODULE__ZLIB",
};

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
        .name = "test",
        .root_module = module,
    });
    unit_tests.linkLibC();

    var flags: std.ArrayList([]const u8) = .empty;
    defer flags.deinit(b.allocator);
    try flags.append(b.allocator, "-DWUFFS_IMPLEMENTATION");
    inline for (defines) |key| {
        try flags.append(b.allocator, "-D" ++ key);
    }

    if (b.lazyDependency("wuffs", .{})) |wuffs_dep| {
        module.addIncludePath(wuffs_dep.path("release/c"));
        {
            const tc = b.addTranslateC(.{
                .root_source_file = b.path("src/c_import.h"),
                .target = target,
                .optimize = optimize,
            });
            if (target.result.os.tag.isDarwin()) {
                const libc = try std.zig.LibCInstallation.findNative(.{
                    .allocator = b.allocator,
                    .target = &target.result,
                    .verbose = false,
                });
                tc.addSystemIncludePath(.{ .cwd_relative = libc.sys_include_dir.? });
            }
            tc.addIncludePath(wuffs_dep.path("release/c"));
            inline for (defines) |key| {
                tc.defineCMacro(key, "1");
            }
            module.addImport("c", tc.createModule());
        }
        module.addCSourceFile(.{
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
