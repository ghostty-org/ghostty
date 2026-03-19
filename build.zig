const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");

const appVersion = @import("build.zig.zon").version;
const minimumZigVersion = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimumZigVersion);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    const config = try buildpkg.Config.init(b, appVersion);
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    // Ghostty dependencies used by many artifacts.
    const deps = try buildpkg.SharedDeps.init(b, &config);

    // The modules exported for Zig consumers of libghostty. If you're
    // writing a Zig program that uses libghostty, read this file.
    const mod = try buildpkg.GhosttyZig.init(
        b,
        &config,
        &deps,
    );

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const libvt_step = b.step("lib-vt", "Build libghostty-vt");
    const run_step = b.step("run", "Run the app");
    const run_valgrind_step = b.step(
        "run-valgrind",
        "Run the app under valgrind",
    );
    const test_step = b.step("test", "Run tests");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libghostty-vt tests",
    );
    const test_valgrind_step = b.step(
        "test-valgrind",
        "Run tests under valgrind",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );

    // Ghostty resources like terminfo, shell integration, themes, etc.
    const resources = try buildpkg.GhosttyResources.init(b, &config, &deps);
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b, &config) else null;

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

    // libghostty (internal, big)
    const libghostty_shared = try buildpkg.GhosttyLib.initShared(
        b,
        &deps,
    );
    const libghostty_static = try buildpkg.GhosttyLib.initStatic(
        b,
        &deps,
    );

    // libghostty-vt
    const libghostty_vt_shared = shared: {
        if (config.target.result.cpu.arch.isWasm()) {
            break :shared try buildpkg.GhosttyLibVt.initWasm(
                b,
                &mod,
            );
        }

        break :shared try buildpkg.GhosttyLibVt.initShared(
            b,
            &mod,
        );
    };
    libghostty_vt_shared.install(libvt_step);
    libghostty_vt_shared.install(b.getInstallStep());

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            resources.install();
            if (i18n) |v| v.install();
        }
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
            if (i18n) |v| v.install();
        }

        // Ghostty macOS app
        const macos_app = try buildpkg.GhosttyXcodebuild.init(
            b,
            &config,
            .{
                .xcframework = &xcframework,
                .docs = &docs,
                .i18n = if (i18n) |v| &v else null,
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
                    .i18n = if (i18n) |v| &v else null,
                    .resources = &resources,
                },
            );

            // Run uses the native macOS app
            run_step.dependOn(&macos_app_native_only.open.step);

            // If we have no test filters, install the tests too
            if (test_filters.len == 0) {
                macos_app_native_only.addTestStepDependencies(test_step);
            }
        }
    }

    // Valgrind
    if (config.app_runtime != .none) {
        // We need to rebuild Ghostty with a baseline CPU target.
        const valgrind_exe = exe: {
            var valgrind_config = config;
            valgrind_config.target = valgrind_config.baselineTarget();
            break :exe try buildpkg.GhosttyExe.init(
                b,
                &valgrind_config,
                &deps,
            );
        };

        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        run_cmd.addArtifactArg(valgrind_exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        run_valgrind_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    {
        const mod_vt_test = b.addTest(.{
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .root_module = mod.vt_c,
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);
    }

    // Tests
    {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(),
                .optimize = .Debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) b.installArtifact(test_exe);
        _ = try deps.add(test_exe);

        // Verify our internal libghostty header.
        const ghostty_h = b.addTranslateC(.{
            .root_source_file = b.path("include/ghostty.h"),
            .target = config.baselineTarget(),
            .optimize = .Debug,
        });
        test_exe.root_module.addImport("ghostty.h", ghostty_h.createModule());

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

        // Valgrind test running
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--num-callers=50",
            b.fmt("--suppressions={s}", .{b.pathFromRoot("valgrind.supp")}),
            "--gen-suppressions=all",
        });
        valgrind_run.addArtifactArg(test_exe);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    if (i18n) |v| {
        translations_step.dependOn(v.update_step);
    } else {
        try translations_step.addError("cannot update translations when i18n is disabled", .{});
    }
}
