const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const run_step = b.step("run", "Run esctest against libghostty-vt");

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        // forkpty and execvp come from libc.
        .link_libc = true,
    });
    if (b.lazyDependency("ghostty", .{})) |dep| {
        exe_mod.addImport(
            "ghostty-vt",
            dep.module("ghostty-vt"),
        );
    }

    const exe = b.addExecutable(.{
        .name = "esctest-libghostty",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    // esctest is Python, so there's nothing to build. It's installed next
    // to the executable, which finds it relative to itself.
    if (b.lazyDependency("esctest2", .{})) |dep| {
        b.installDirectory(.{
            .source_dir = dep.path("esctest"),
            .install_dir = .prefix,
            .install_subdir = "share/esctest",
            .exclude_extensions = &.{".pyc"},
        });
    }

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    run_step.dependOn(&run_cmd.step);
}
