const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run the app");

    const exe_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addCSourceFiles(.{
        .root = b.path("src"),
        .files = &.{"main.c"},
    });

    // You'll want to use a lazy dependency here so that ghostty is only
    // downloaded if you actually need it.
    if (b.lazyDependency("ghostty", .{
        // Setting simd to false will force a pure static build that
        // doesn't even require libc, but it has a significant performance
        // penalty. If your embedding app requires libc anyway, you should
        // always keep simd enabled.
        // .simd = false,
    })) |dep| {
        exe_mod.linkLibrary(dep.artifact("ghostty-vt"));
    }

    // Exe
    const exe = b.addExecutable(.{
        .name = "c_vt_key_encode",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // Run
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    run_step.dependOn(&run_cmd.step);
}
