const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const module = b.addModule("libjxl", .{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    var test_exe: ?*std.Build.Step.Compile = null;
    if (target.query.isNative()) {
        test_exe = b.addTest(.{
            .name = "test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("main.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const tests_run = b.addRunArtifact(test_exe.?);
        const test_step = b.step("test", "Run tests");
        test_step.dependOn(&tests_run.step);
    }

    // libjxl is complex to build from source (requires brotli, highway, etc.)
    // so we use system integration for now.
    // TODO: Add source build support similar to freetype
    module.linkSystemLibrary("libjxl", dynamic_link_opts);
    module.linkSystemLibrary("libjxl_threads", dynamic_link_opts);
    if (test_exe) |exe| {
        exe.linkSystemLibrary2("libjxl", dynamic_link_opts);
        exe.linkSystemLibrary2("libjxl_threads", dynamic_link_opts);
    }
}
