const std = @import("std");
const translate_c = @import("translate_c");

// All the C macros defined so that the header matches the build.
const defines = [_][]const u8{
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
    });

    const unit_tests = b.addTest(.{
        .name = "test",
        .root_module = module,
    });

    // Windows always has a libc available.
    const windows = target.result.os.tag == .windows;

    translate: {
        const wuffs_dep = b.lazyDependency("wuffs", .{}) orelse break :translate;
        const include_paths: []const std.Build.LazyPath = switch (windows) {
            true => &.{wuffs_dep.path("release/c")},

            // Wuffs only needs stdlib.h and string.h from libc, and only for
            // a handful of declarations. We provide minimal versions of these
            // headers so that wuffs can be translated and compiled without
            // libc, notably for freestanding targets (wasm32) but this also
            // avoids requiring an Apple SDK for translate-c on macOS.
            false => &.{ b.path("include"), wuffs_dep.path("release/c") },
        };

        // Split up macro flags so that we can add them to translation
        const macro_flags = macro_flags: {
            var flag_builder: std.ArrayList([]const u8) = try .initCapacity(b.allocator, defines.len);
            inline for (defines) |key| {
                flag_builder.appendAssumeCapacity("-D" ++ key);
            }
            break :macro_flags flag_builder.items;
        };

        // Larger flag set for C file build within module
        const c_flags = c_flags: {
            var len: usize = macro_flags.len + 1;
            if (windows) len += 2;
            var flag_builder: std.ArrayList([]const u8) = try .initCapacity(b.allocator, len);

            flag_builder.appendAssumeCapacity("-DWUFFS_IMPLEMENTATION");

            // Disable ubsan on Windows to avoid undefined __ubsan_handle_*
            // references: Zig's ubsan runtime can't be bundled on Windows
            // (its /exclude-symbols directives break the MSVC linker), so
            // these handlers would go unresolved. This affects both the
            // MSVC and GNU ABIs.
            if (windows) {
                flag_builder.appendAssumeCapacity("-fno-sanitize=undefined");
                flag_builder.appendAssumeCapacity("-fno-sanitize-trap=undefined");
            }

            for (macro_flags) |f| flag_builder.appendAssumeCapacity(f);

            break :c_flags flag_builder.items;
        };

        const wuffs_c = try translate_c.init(b, .{
            .source = .{ .includes = .{
                .generated_name = "wuffs_c.h",
                .files = &.{.{ .path = "wuffs-v0.4.c" }},
            } },
            .target = target,
            .optimize = optimize,
            .include_paths = include_paths,
            .link_libc = windows,
            .extra_args = macro_flags,
        });

        wuffs_c.mod.addCSourceFile(.{
            .file = wuffs_dep.path("release/c/wuffs-v0.4.c"),
            .flags = c_flags,
        });

        module.addImport("wuffs_c", wuffs_c.mod);
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
