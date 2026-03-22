const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "c_embedded_gtk",
        .root_module = mod,
    });
    exe.linkLibC();
    exe.addIncludePath(b.path("../../include"));
    exe.addIncludePath(b.path("../../src/apprt/gtk"));
    exe.addLibraryPath(b.path("../../zig-out/lib"));
    exe.addCSourceFile(.{
        .file = b.path("src/main.c"),
        .flags = &.{},
    });
    exe.linkSystemLibrary2("ghostty", .{ .use_pkg_config = .no });
    exe.linkSystemLibrary2("gtk4", .{ .use_pkg_config = .yes });
    exe.linkSystemLibrary2("libadwaita-1", .{ .use_pkg_config = .yes });

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the embedded GTK smoke test");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.setEnvironmentVariable("LD_LIBRARY_PATH", b.pathFromRoot("../../zig-out/lib"));
    run_cmd.setEnvironmentVariable("GHOSTTY_RESOURCES_DIR", b.pathFromRoot("../../zig-out/share/ghostty"));
    run_step.dependOn(&run_cmd.step);
}
