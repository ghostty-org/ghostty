const std = @import("std");
const assert = std.debug.assert;
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
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin()) {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle.
        docs.installDummy(b.getInstallStep());
    }

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

    // libghostty
    const libghostty_shared = try buildpkg.GhosttyLib.initShared(
        b,
        &deps,
    );
    const libghostty_static = try buildpkg.GhosttyLib.initStatic(
        b,
        &deps,
    );

    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        exe.install();
        resources.install();
        i18n.install();
    } else {
        // Libghostty
        //
        // Note: libghostty is not stable for general purpose use. It is used
        // heavily by Ghostty on macOS but it isn't built to be reusable yet.
        // As such, these build steps are lacking. For example, the Darwin
        // build only produces an xcframework.

        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            libghostty_shared.installHeader(); // Only need one header
            libghostty_shared.install("libghostty.so");
            libghostty_static.install("libghostty.a");
        }
    }

    // macOS only artifacts. These will error if they're initialized for
    // other targets.
    if (config.target.result.os.tag.isDarwin()) {
        // Ghostty xcframework
        const xcframework = try buildpkg.GhosttyXCFramework.init(
            b,
            &deps,
            config.xcframework_target,
        );
        if (config.emit_xcframework) {
            xcframework.install();

            // The xcframework build always installs resources because our
            // macOS xcode project contains references to them.
            resources.install();
            i18n.install();
        }

        // Ghostty macOS app
        const macos_app = try buildpkg.GhosttyXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .i18n = &i18n,
                .resources = &resources,
            },
        );
        if (config.emit_macos_app) {
            macos_app.install();
        }
    }

    // Run step
    run: {
        if (config.app_runtime != .none) {
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
            break :run;
        }

        assert(config.app_runtime == .none);

        // On macOS we can run the macOS app. For "run" we always force
        // a native-only build so that we can run as quickly as possible.
        if (config.target.result.os.tag.isDarwin()) {
            const xcframework_native = try buildpkg.GhosttyXCFramework.init(
                b,
                &deps,
                .native,
            );
            const macos_app_native_only = try buildpkg.GhosttyXcodebuild.init(
                b,
                &config,
                .{
                    .xcframework = &xcframework_native,
                    .docs = &docs,
                    .i18n = &i18n,
                    .resources = &resources,
                },
            );

            const run_step = b.step("run", "Run the app");
            run_step.dependOn(&macos_app_native_only.open.step);
        }
    }

    // Tests
    {
        const test_step = b.step("test", "Run all tests");
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");

        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = if (test_filter) |v| &.{v} else &.{},
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.target,
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
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
