const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const buildpkg = @import("src/build/main.zig");
const translate_c = @import("translate_c");

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// The libghostty-vt version, released separately from the app with
/// `vt-X.Y.Z` tags. See `Config.libVersion` for how builds use it.
///
/// CMakeLists.txt and CI read this line with a regular expression, so
/// keep it on one line in this form.
const lib_version = "0.1.0-dev";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    buildpkg.requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // Source tarballs have no git history, so they carry their version
    // in a VERSION (app) or LIB_VERSION (libghostty-vt) file.
    const config = try buildpkg.Config.init(b, .{
        .app = app_zon_version,
        .app_file = readVersionFile(b, "VERSION"),
        .lib = lib_version,
        .lib_file = readVersionFile(b, "LIB_VERSION"),
    });
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
    const test_lib_vt_build_step = b.step(
        "test-lib-vt-build",
        "Build libghostty-vt tests without running them (compile check)",
    );
    const test_lib_vt_schema_step = b.step(
        "test-lib-vt-schema",
        "Validate the libghostty-vt ABI type manifest",
    );
    const test_lib_vt_abi_step = b.step(
        "test-lib-vt-abi",
        "Fail if libghostty-vt changed its ABI in a way that is not an addition",
    );
    const update_lib_vt_abi_step = b.step(
        "update-lib-vt-abi",
        "Record the libghostty-vt ABI of the current target in src/terminal/c/abi",
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
    // Only the app uses them, so a libghostty-vt build skips them, which
    // also keeps it from downloading the themes package. This is null only
    // when emit_lib_vt is set, and every use below is in an app-only branch.
    const resources: ?buildpkg.GhosttyResources = if (config.emit_lib_vt)
        null
    else
        try buildpkg.GhosttyResources.init(b, &config, &deps);
    const i18n = if (config.i18n) try buildpkg.GhosttyI18n.init(b, &config) else null;

    // Ghostty executable, the actual runnable Ghostty program.
    const exe = try buildpkg.GhosttyExe.init(b, &config, &deps);

    // Ghostty docs
    const docs = try buildpkg.GhosttyDocs.init(b, &deps);
    if (config.emit_docs) {
        docs.install();
    } else if (config.target.result.os.tag.isDarwin() and
        !config.emit_lib_vt)
    {
        // If we aren't emitting docs we need to emit a placeholder so
        // our macOS xcodeproject builds since it expects the `share/man`
        // directory to exist to copy into the app bundle. A libghostty-vt
        // build has no app bundle, so it doesn't need one.
        docs.installDummy(b.getInstallStep());
    }

    // Ghostty webdata
    const webdata = try buildpkg.GhosttyWebdata.init(b, &deps);
    if (config.emit_webdata) webdata.install();

    // Ghostty bench tools
    if (config.emit_bench) {
        const bench = try buildpkg.GhosttyBench.init(b, &deps);
        bench.install();
    }

    // Ghostty dist tarball
    const dist = try buildpkg.GhosttyDist.init(b, &config);
    {
        const step = b.step("dist", "Build the dist tarball");
        step.dependOn(dist.install_step);
        const check_step = b.step("distcheck", "Install and validate the dist tarball");
        check_step.dependOn(dist.check_step);
        check_step.dependOn(dist.install_step);
        // Only libghostty-vt builds (-Demit-lib-vt) have this step.
        if (dist.deps_install_step) |deps_install| {
            const deps_step = b.step(
                "dist-deps",
                "Build the libghostty-vt dependency tarball for offline builds (needs network)",
            );
            deps_step.dependOn(deps_install);
        }
    }

    // libghostty-vt
    //
    // The libraries are always defined so that steps like test-lib-vt can
    // use them, but they are only installed by a libghostty-vt build or
    // when Ghostty is a dependency. A dependency must install them so
    // that dep.artifact("ghostty-vt") and friends can find them. App
    // builds install none of it, so they don't ship a stray C library.
    const install_lib_vt = config.emit_lib_vt or config.is_dep;
    const native_freestanding = config.target.result.os.tag == .freestanding and
        !config.target.result.cpu.arch.isWasm();
    const libghostty_vt_shared: ?buildpkg.GhosttyLibVt = shared: {
        if (config.target.result.cpu.arch.isWasm()) {
            break :shared try buildpkg.GhosttyLibVt.initWasm(
                b,
                &mod,
            );
        }
        if (native_freestanding) break :shared null;

        break :shared try buildpkg.GhosttyLibVt.initShared(
            b,
            &mod,
            config.is_dep,
        );
    };
    if (libghostty_vt_shared) |shared| {
        if (install_lib_vt) shared.install(b.getInstallStep());

        const type_schema_test = b.addSystemCommand(&.{"python3"});
        type_schema_test.addFileArg(b.path("src/terminal/c/types-schema-verify.py"));
        type_schema_test.addFileArg(b.path("src/terminal/c/types.schema.json"));
        type_schema_test.addFileArg(shared.output);
        test_lib_vt_schema_step.dependOn(&type_schema_test.step);

        shared.addAbiCheck(b, config.target.result, test_lib_vt_abi_step, update_lib_vt_abi_step);
    } else {
        _ = b.addFail("cannot execute the ABI manifest for a native freestanding target");
    }

    // The packages libghostty-vt uses, for gen-lib-vt-deps.sh. Defined
    // only for library builds so app builds skip reading every package's
    // build.zig.zon.
    if (config.emit_lib_vt) _ = try buildpkg.LibVtPackages.init(b, mod.vt_c);

    // libghostty-vt static lib
    const libghostty_vt_static = try buildpkg.GhosttyLibVt.initStatic(
        b,
        &mod,
    );
    if (config.is_dep) {
        // If we're a dependency, we need to install everything as-is
        // so that dep.artifact("ghostty-vt-static") works.
        libghostty_vt_static.install(b.getInstallStep());
    } else if (install_lib_vt) {
        // If we're not a dependency, we rename the static lib to
        // be idiomatic. On Windows, we use a distinct name to avoid
        // colliding with the DLL import library (ghostty-vt.lib).
        const static_lib_name = if (config.target.result.os.tag == .windows)
            "ghostty-vt-static.lib"
        else
            "libghostty-vt.a";
        b.getInstallStep().dependOn(&b.addInstallLibFile(
            libghostty_vt_static.output,
            static_lib_name,
        ).step);

        if (native_freestanding) {
            b.getInstallStep().dependOn(&b.addInstallDirectory(.{
                .source_dir = b.path("include/ghostty"),
                .install_dir = .header,
                .install_subdir = "ghostty",
                .include_extensions = &.{".h"},
            }).step);
        }
    }

    // libghostty-vt xcframework (Apple only, universal binary).
    // Only when building on macOS (not cross-compiling) since
    // xcodebuild is required.
    if (config.emit_lib_vt and
        config.emit_xcframework and
        builtin.target.os.tag.isDarwin() and
        config.target.result.os.tag.isDarwin())
    {
        const apple_libs = try buildpkg.GhosttyLibVt.initStaticAppleUniversal(
            b,
            &config,
            &deps,
            &mod,
        );
        const xcframework = buildpkg.GhosttyLibVt.xcframework(&apple_libs, b);
        b.getInstallStep().dependOn(xcframework.step);
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    // Runtime "none" is libghostty, anything else is an executable.
    if (config.app_runtime != .none) {
        if (config.emit_exe) {
            exe.install();
            if (resources) |v| v.install();
            if (i18n) |v| v.install();
        }
    } else if (!config.emit_lib_vt) {
        // The macOS Ghostty Library
        //
        // This is NOT libghostty (even though its named that for historical
        // reasons). It is just the glue between Ghostty GUI on macOS and
        // the full Ghostty GUI core.
        const lib_shared = try buildpkg.GhosttyLib.initShared(b, &deps);
        const lib_static = try buildpkg.GhosttyLib.initStatic(b, &deps);

        // We shouldn't have this guard but we don't currently
        // build on macOS this way ironically so we need to fix that.
        if (!config.target.result.os.tag.isDarwin()) {
            lib_shared.installHeader(); // Only need one header
            if (config.target.result.os.tag == .windows) {
                lib_shared.install("ghostty-internal.dll");
                lib_static.install("ghostty-internal-static.lib");
            } else {
                lib_shared.install("ghostty-internal.so");
                lib_static.install("ghostty-internal.a");
            }
        }
    }

    // macOS only artifacts. These will error if they're initialized for
    // other targets. In lib-vt mode emit_xcframework controls the lib-vt
    // xcframework above, not this one.
    if (!config.emit_lib_vt and config.target.result.os.tag.isDarwin() and
        (config.emit_xcframework or config.emit_macos_app))
    {
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
            resources.?.install();
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
                .resources = &resources.?,
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
            run_cmd.addPassthruArgs();

            // Set the proper resources dir so things like shell integration
            // work correctly. If we're running `zig build run` in Ghostty,
            // this also ensures it overwrites the release one with our debug
            // build.
            // FIXME: This is not possible after Zig 0.17.
            // run_cmd.setEnvironmentVariable(
            //     "GHOSTTY_RESOURCES_DIR",
            //     b.getInstallPath(.prefix, "share/ghostty"),
            // );

            run_step.dependOn(&run_cmd.step);
            break :run;
        }

        assert(config.app_runtime == .none);

        // On macOS we can run the macOS app. For "run" we always force
        // a native-only build so that we can run as quickly as possible.
        if (!config.emit_lib_vt and
            config.target.result.os.tag.isDarwin() and
            (config.emit_xcframework or config.emit_macos_app))
        {
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
                    .resources = &resources.?,
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
            valgrind_config.target = valgrind_config.baselineTarget(b.graph.io);
            break :exe try buildpkg.GhosttyExe.init(
                b,
                &valgrind_config,
                &deps,
            );
        };

        const run_cmd = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--error-exitcode=1",
            "--num-callers=50",
            "--gen-suppressions=all",
        });
        run_cmd.addFileArg2(b.path("valgrind.supp"), .{ .prefix = "--suppressions=" });
        run_cmd.addArtifactArg(valgrind_exe.exe);
        run_cmd.addPassthruArgs();
        run_valgrind_step.dependOn(&run_cmd.step);
    }

    // Zig module tests
    {
        const mod_vt_test = b.addTest(.{
            .name = "ghostty-vt-test",
            .root_module = mod.vt,
            .filters = test_filters,
        });
        const mod_vt_test_run = b.addRunArtifact(mod_vt_test);
        test_lib_vt_step.dependOn(&mod_vt_test_run.step);

        const mod_vt_c_test = b.addTest(.{
            .name = "ghostty-vt-c-test",
            .root_module = try buildpkg.GhosttyZig.initVtCTest(b, &config, &deps),
            .filters = test_filters,
        });
        const mod_vt_c_test_run = b.addRunArtifact(mod_vt_c_test);
        test_lib_vt_step.dependOn(&mod_vt_c_test_run.step);

        // The committed version.h must match lib_version, so a version
        // bump has to update both. The test embeds the header, so both
        // files are copied into one directory.
        const version_h_test = version_h_test: {
            const wf = b.addWriteFiles();
            const root = wf.addCopyFile(
                b.path("src/terminal/c/version_h_test.zig"),
                "version_h_test.zig",
            );
            _ = wf.addCopyFile(
                b.path("include/ghostty/vt/version.h"),
                "version.h",
            );
            const opts = b.addOptions();
            opts.addOption(std.SemanticVersion, "lib_version", config.lib_version);
            const test_mod = b.createModule(.{
                .root_source_file = root,
                .target = b.graph.host,
                .optimize = .debug,
            });
            test_mod.addOptions("lib_version", opts);
            break :version_h_test b.addTest(.{
                .name = "ghostty-vt-version-h-test",
                .root_module = test_mod,
                .filters = test_filters,
            });
        };
        test_lib_vt_step.dependOn(&b.addRunArtifact(version_h_test).step);

        // The public headers must compile without warnings in every
        // language standard we support, so compile a file that includes
        // vt.h once per standard with strict warnings as errors.
        {
            const wf = b.addWriteFiles();
            const c_src = wf.add("vt_h_test.c", "#include <ghostty/vt.h>\n");
            const cpp_src = wf.add("vt_h_test.cpp", "#include <ghostty/vt.h>\n");
            const warnings: []const []const u8 = &.{
                "-Wall",
                "-Wextra",
                "-Wpedantic",
                "-Werror",
            };
            const Case = struct { std: []const u8, src: std.Build.LazyPath };
            const cases: []const Case = &.{
                .{ .std = "c11", .src = c_src },
                .{ .std = "c23", .src = c_src },
                .{ .std = "c++17", .src = cpp_src },
            };
            for (cases) |case| {
                const flags = std.mem.concat(b.allocator, []const u8, &.{
                    &.{b.fmt("-std={s}", .{case.std})},
                    warnings,
                }) catch @panic("OOM");
                const obj_mod = b.createModule(.{
                    .target = b.graph.host,
                    .optimize = .debug,
                    .link_libc = true,
                    .link_libcpp = std.mem.startsWith(u8, case.std, "c++"),
                });
                obj_mod.addIncludePath(b.path("include"));
                obj_mod.addCSourceFile(.{ .file = case.src, .flags = flags });
                const obj = b.addObject(.{
                    .name = b.fmt("vt-h-{s}", .{case.std}),
                    .root_module = obj_mod,
                });
                test_lib_vt_step.dependOn(&obj.step);
            }
        }

        if (config.emit_test_exe) {
            // With -Demit-test-exe, test-lib-vt-build builds only the C API
            // test binary and installs it to zig-out/bin, so it can run on
            // another machine. CI uses this to run it in a FreeBSD VM. The
            // C API binary already runs every test in the Zig one, and
            // compiling both at once can run a CI runner out of memory.
            const install = b.addInstallArtifact(mod_vt_c_test, .{});
            test_lib_vt_build_step.dependOn(&install.step);
        } else {
            test_lib_vt_build_step.dependOn(&mod_vt_test.step);
            test_lib_vt_build_step.dependOn(&mod_vt_c_test.step);
        }
    }

    // Tests (skip when building libghostty-vt)
    if (!config.emit_lib_vt) {
        // Full unit tests
        const test_exe = b.addTest(.{
            .name = "ghostty-test",
            .filters = test_filters,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = config.baselineTarget(b.graph.io),
                .optimize = .debug,
                .strip = false,
                .omit_frame_pointer = false,
                .unwind_tables = .sync,
            }),
            // Crash on x86_64 without this
            .use_llvm = true,
        });
        if (config.emit_test_exe) {
            const test_exe_install = b.addInstallArtifact(test_exe, .{});
            config.addPatchElf(test_exe, &test_exe_install.step);
            test_step.dependOn(&test_exe_install.step);
        }
        _ = try deps.add(test_exe);

        addGhosttyH(b, test_exe.root_module, config.baselineTarget(b.graph.io), .debug);

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        config.addPatchElf(test_exe, &test_run.step);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

        // Valgrind test running
        const valgrind_run = b.addSystemCommand(&.{
            "valgrind",
            "--leak-check=full",
            "--error-exitcode=1",
            "--num-callers=50",
            "--gen-suppressions=all",
        });
        valgrind_run.addFileArg2(b.path("valgrind.supp"), .{ .prefix = "--suppressions=" });
        valgrind_run.addArtifactArg(test_exe);
        config.addPatchElf(test_exe, &valgrind_run.step);
        test_valgrind_step.dependOn(&valgrind_run.step);
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    if (i18n) |v| {
        translations_step.dependOn(v.update_step);
    } else {
        _ = b.addFail("cannot update translations when i18n is disabled");
    }
}

fn addGhosttyH(
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
) void {
    translate_c.addImportToModule(b, "ghostty.h", module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "ghostty.h" },
        } } },
        .target = target,
        .optimize = optimize,
        .system_include_paths = &.{b.path("include")},
    }) catch unreachable;
}

/// Returns the trimmed contents of `name` in the build root, or null if
/// it doesn't exist.
fn readVersionFile(b: *std.Build, name: []const u8) ?[]const u8 {
    const content = b.root.root_dir.handle.readFileAlloc(
        b.graph.io,
        name,
        b.allocator,
        .limited(128),
    ) catch return null;
    return std.mem.trim(u8, content, &std.ascii.whitespace);
}
