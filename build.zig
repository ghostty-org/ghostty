const std = @import("std");
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

comptime {
    buildpkg.requireZig("0.14.0");
}

pub fn build(b: *std.Build) !void {
    const config = try buildpkg.Config.init(b);

    // Ghostty resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config);
    const i18n = try buildpkg.GhosttyI18n.init(b, &config);

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);
    if (config.emit_helpgen) deps.help_strings.install();

    // Ghostty executable, the actual runnable Ghostty program.
    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);

    // Ghostty docs
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) docs.install();

    // Ghostty webdata
    const webdata = try buildpkg.GhosttyWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();

    // Ghostty bench tools
    const bench = try buildpkg.GhosttyBench.init(b, &deps);
    if (config.emit_bench) bench.install();

    // Ghostty dist tarball
    const dist = try buildpkg.GhosttyDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
    }

    // If we're not building libghostty, then install the exe and resources.
    if (config.app_runtime != .none) {
        exe.install();
        resources.install();
        i18n.install();
    }

    // Libghostty
    //
    // Note: libghostty is not stable for general purpose use. It is used
    // heavily by Ghostty on macOS but it isn't built to be reusable yet.
    // As such, these build steps are lacking. For example, the Darwin
    // build only produces an xcframework.
    if (config.app_runtime == .none) {
        if (config.target.result.os.tag.isDarwin()) darwin: {
            if (!config.emit_xcframework) break :darwin;

            // Build the xcframework
            const xcframework = try buildpkg.GhosttyXCFramework.init(b, &deps);
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
            i18n.install();

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

        // Set the proper resources dir so things like shell integration
        // work correctly. If we're running `zig build run` in Ghostty,
        // this also ensures it overwrites the release one with our debug
        // build.
        run_cmd.setEnvironmentVariable(
            "GHOSTTY_RESOURCES_DIR",
            b.getInstallPath(.prefix, "share/ghostty"),
        );

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

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    {
        const step = b.step("update-translations", "Update translation files");
        step.dependOn(i18n.update_step);
    }
}
