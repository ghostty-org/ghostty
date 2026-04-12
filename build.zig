const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const requireZig = @import("src/build/zig.zig").requireZig;

/// App version from build.zig.zon.
const app_zon_version = @import("build.zig.zon").version;

/// Libghostty version. We use a separate version from the app.
const lib_version = "0.1.0";

/// Minimum required zig version.
const minimum_zig_version = @import("build.zig.zon").minimum_zig_version;

comptime {
    requireZig(minimum_zig_version);
}

pub fn build(b: *std.Build) !void {
    const BuildConfig = @import("src/build/Config.zig");
    const SharedDeps = @import("src/build/SharedDeps.zig");
    const GhosttyExe = @import("src/build/GhosttyExe.zig");
    // This defines all the available build options (e.g. `-D`). If you
    // want to know what options are available, you can run `--help` or
    // you can read `src/build/Config.zig`.

    // If we have a VERSION file (present in source tarballs) then we
    // use that as the version source of truth. Otherwise we fall back
    // to what is in the build.zig.zon.
    const file_version: ?[]const u8 = if (b.build_root.handle.readFileAlloc(
        b.allocator,
        "VERSION",
        128,
    )) |content| std.mem.trim(
        u8,
        content,
        &std.ascii.whitespace,
    ) else |_| null;

    const config = try BuildConfig.init(
        b,
        file_version orelse app_zon_version,
    );
    const test_filters = b.option(
        [][]const u8,
        "test-filter",
        "Filter for test. Only applies to Zig tests.",
    ) orelse &[0][]const u8{};

    const want_lib_vt_graph = config.emit_lib_vt or config.is_dep;
    const want_test_graph =
        config.emit_test_exe or
        test_filters.len > 0 or
        want_lib_vt_graph;

    // Ghostty dependencies used by many artifacts.
    const deps = try SharedDeps.init(b, &config);

    // All our steps which we'll hook up later. The steps are shown
    // up here just so that they are more self-documenting.
    const run_step = b.step("run", "Run the app");
    const run_valgrind_step = b.step(
        "run-valgrind",
        "Compatibility stub: valgrind is not supported in the Windows-only fork",
    );
    const test_step = b.step("test", "Run tests");
    const test_lib_vt_step = b.step(
        "test-lib-vt",
        "Run libghostty-vt tests",
    );
    const test_valgrind_step = b.step(
        "test-valgrind",
        "Compatibility stub: valgrind is not supported in the Windows-only fork",
    );
    const translations_step = b.step(
        "update-translations",
        "Update translation files",
    );

    // The Windows-only fork doesn't generate Unix-focused install resources
    // for the default local exe build. They can remain opt-in elsewhere.
    const install_resources =
        config.emit_exe and
        config.app_runtime != .none and
        config.target.result.os.tag != .windows;
    const resources = if (install_resources) resources: {
        const GhosttyResources = @import("src/build/GhosttyResources.zig");
        break :resources try GhosttyResources.init(b, &config, &deps);
    } else null;

    // Ghostty executable, the actual runnable Ghostty program.
    const exe = try GhosttyExe.init(b, &config, &deps);

    // libghostty-vt is retained in this fork, but normal app builds
    // shouldn't pay to build/install it unless explicitly requested.
    if (want_lib_vt_graph) {
        const GhosttyZig = @import("src/build/GhosttyZig.zig");
        const GhosttyLibVt = @import("src/build/GhosttyLibVt.zig");

        // The modules exported for Zig consumers of libghostty-vt.
        const mod = try GhosttyZig.init(
            b,
            &config,
            &deps,
        );

        const libghostty_vt_shared = shared: {
            if (config.target.result.cpu.arch.isWasm()) {
                break :shared try GhosttyLibVt.initWasm(
                    b,
                    &mod,
                );
            }

            break :shared try GhosttyLibVt.initShared(
                b,
                &mod,
            );
        };
        libghostty_vt_shared.install(b.getInstallStep());

        // libghostty-vt static lib
        const libghostty_vt_static = try GhosttyLibVt.initStatic(
            b,
            &mod,
        );
        if (config.is_dep) {
            // If we're a dependency, we need to install everything as-is
            // so that dep.artifact("ghostty-vt-static") works.
            libghostty_vt_static.install(b.getInstallStep());
        } else {
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
        }
    }

    // Helpgen
    if (config.emit_helpgen) deps.help_strings.install();

    if (config.emit_exe and config.app_runtime != .none) {
        exe.install();
        if (resources) |r| r.install();
    }

    // Run step
    if (config.app_runtime != .none) {
        const run_cmd = b.addRunArtifact(exe.exe);
        if (b.args) |args| run_cmd.addArgs(args);
        if (install_resources) run_cmd.setEnvironmentVariable(
            "GHOSTTY_RESOURCES_DIR",
            b.getInstallPath(.prefix, "share/ghostty"),
        );
        run_step.dependOn(&run_cmd.step);
    }

    try run_valgrind_step.addError(
        "run-valgrind is not supported in the Windows-only fork",
        .{},
    );

    // Zig module tests
    if (want_lib_vt_graph) {
        const GhosttyZig = @import("src/build/GhosttyZig.zig");
        const mod = try GhosttyZig.init(
            b,
            &config,
            &deps,
        );

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
    } else {
        try test_lib_vt_step.addError(
            "test-lib-vt requires -Demit-lib-vt=true in the Windows-only fork",
            .{},
        );
    }

    // Tests
    if (want_test_graph) {
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

        // Normal test running
        const test_run = b.addRunArtifact(test_exe);
        test_step.dependOn(&test_run.step);

        // Normal tests always test our libghostty modules
        //test_step.dependOn(test_lib_vt_step);

        try test_valgrind_step.addError(
            "test-valgrind is not supported in the Windows-only fork",
            .{},
        );
    } else {
        try test_step.addError(
            "test requires -Dtest-filter=<name> or -Demit-test-exe=true in the Windows-only fork",
            .{},
        );
        try test_valgrind_step.addError(
            "test-valgrind is not supported in the Windows-only fork",
            .{},
        );
    }

    // update-translations does what it sounds like and updates the "pot"
    // files. These should be committed to the repo.
    try translations_step.addError("update-translations is not supported in the Windows-only fork", .{});
}
