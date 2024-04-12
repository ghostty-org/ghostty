const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zig_js_module = b.addModule("zig-js", .{ .root_source_file = .{ .path = "src/main.zig" } });

    const test_exe = b.addTest(.{
        .name = "js-test",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(test_exe);

    const test_step = b.step("test", "Run tests");
    const tests_run = b.addRunArtifact(test_exe);
    test_step.dependOn(&tests_run.step);

    // Example
    {
        const wasm = b.addExecutable(.{
            .name = "example",
            .root_source_file = .{ .path = "example/main.zig" },
            .target = b.resolveTargetQuery(.{
                .cpu_arch = .wasm32,
                .os_tag = .freestanding,
            }),
            .optimize = optimize,
        });
        wasm.root_module.addImport("zig-js", zig_js_module);
        wasm.entry = .disabled;
        wasm.export_memory = true;

        // custom's path is relative to zig-out
        const wasm_install = b.addInstallFileWithDir(
            wasm.getEmittedBin(),
            .{ .custom = "../example" },
            "example.wasm",
        );

        const step = b.step("example", "Build the example project (Zig only)");
        step.dependOn(&wasm_install.step);
    }
}
