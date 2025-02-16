const std = @import("std");
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

comptime {
    buildpkg.requireZig("0.13.0");
}

pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b);

    // Ghostty resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config);

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);
    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);
    if (config.emit_helpgen) deps.help_strings.install();

    // Ghostty docs
    if (config.emit_docs) {
        const docs = try buildpkg.GhosttyDocs.init(b, &deps);
        docs.install();
    }

    // Ghostty webdata
    if (config.emit_webdata) {
        const webdata = try buildpkg.GhosttyWebdata.init(b, &deps);
        webdata.install();
    }

    // Ghostty bench tools
    if (config.emit_bench) {
        const bench = try buildpkg.GhosttyBench.init(b, &deps);
        bench.install();
    }

    // If we're not building libghostty, then install the exe and resources.
    if (config.app_runtime != .none) {
        exe.install();
        resources.install();
    }

    // Libghostty
    //
    // Note: libghostty is not stable for general purpose use. It is used
    // heavily by Ghostty on macOS but it isn't built to be reusable yet.
    // As such, these build steps are lacking. For example, the Darwin
    // build only produces an xcframework.
    if (config.app_runtime == .none) {
        if (config.target.result.isDarwin()) darwin: {
            if (!config.emit_xcframework) break :darwin;

            // Build the xcframework
            const xcframework = try buildpkg.GhosttyXCFramework.init(b, &deps);
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();

            // If we aren't emitting docs we need to emit a placeholder so
            // our macOS xcodeproject builds.
            if (!config.emit_docs) {
                var wf = b.addWriteFiles();
                const path = "share/man/.placeholder";
                const placeholder = wf.add(path, "emit-docs not true so no man pages");
                b.getInstallStep().dependOn(&b.addInstallFile(placeholder, path).step);
            }
        } else {
            const libghostty_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
            const libghostty_static = try buildpkg.GhosttyLib.initStatic(b, &deps);
            libghostty_shared.installHeader(); // Only need one header
            libghostty_shared.install("libghostty.so");
            libghostty_static.install("libghostty.a");
        }
    }

    // Run runs the Ghostty exe
    {
        const run_cmd = b.addRunArtifact(exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_step = b.step("test", "Run all tests");
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");

        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .root_source_file = b.path("src/main.zig"),
            .target = config.target,
            .filter = test_filter,
        });

        {
            if (config.emit_test_exe) b.installArtifact(test_exe);
            _ = try deps.add(test_exe);
            const test_run = b.addRunArtifact(test_exe);
            test_step.dependOn(&test_run.step);
        }
    }
}
