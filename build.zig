const std = @import("std");
const fs = std.fs;
const Builder = std.build.Builder;
const LibExeObjStep = std.build.LibExeObjStep;
const glfw = @import("vendor/mach/libs/glfw/build.zig");
const fontconfig = @import("pkg/fontconfig/build.zig");
const freetype = @import("pkg/freetype/build.zig");
const harfbuzz = @import("pkg/harfbuzz/build.zig");
const libxml2 = @import("vendor/zig-libxml2/libxml2.zig");
const libuv = @import("pkg/libuv/build.zig");
const libpng = @import("pkg/libpng/build.zig");
const macos = @import("pkg/macos/build.zig");
const utf8proc = @import("pkg/utf8proc/build.zig");
const zlib = @import("pkg/zlib/build.zig");
const tracylib = @import("pkg/tracy/build.zig");
const system_sdk = @import("vendor/mach/libs/glfw/system_sdk.zig");

// Build options, see the build options help for more info.
var tracy: bool = false;
var enable_coretext: bool = false;
var enable_fontconfig: bool = false;

pub fn build(b: *std.build.Builder) !void {
    const mode = b.standardReleaseOptions();
    const target = target: {
        var result = b.standardTargetOptions(.{});

        if (result.isLinux() and result.isGnuLibC()) {
            // https://github.com/ziglang/zig/issues/9485
            result.glibc_version = .{ .major = 2, .minor = 28 };
        }

        break :target result;
    };

    tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy integration (default true in Debug on Linux)",
    ) orelse (mode == .Debug and target.isLinux());

    enable_coretext = b.option(
        bool,
        "coretext",
        "Enable coretext for font discovery (default true on macOS)",
    ) orelse target.isDarwin();

    enable_fontconfig = b.option(
        bool,
        "fontconfig",
        "Enable fontconfig for font discovery (default true on Linux)",
    ) orelse target.isLinux();

    const static = b.option(
        bool,
        "static",
        "Statically build as much as possible for the exe",
    ) orelse true;

    const conformance = b.option(
        []const u8,
        "conformance",
        "Name of the conformance app to run with 'run' option.",
    );

    const emit_test_exe = b.option(
        bool,
        "test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    const exe = b.addExecutable("ghostty", "src/main.zig");
    const exe_options = b.addOptions();
    exe_options.addOption(bool, "tracy_enabled", tracy);
    exe_options.addOption(bool, "coretext", enable_coretext);
    exe_options.addOption(bool, "fontconfig", enable_fontconfig);

    // Exe
    {
        exe.setTarget(target);
        exe.setBuildMode(mode);
        exe.addOptions("build_options", exe_options);
        exe.install();

        // Add the shared dependencies
        try addDeps(b, exe, static);
    }

    // term.wasm
    {
        const wasm = b.addSharedLibrary(
            "ghostty-term",
            "src/terminal/main_wasm.zig",
            .{ .unversioned = {} },
        );
        wasm.setTarget(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        wasm.setBuildMode(mode);
        wasm.setOutputDir("zig-out");

        // Wasm-specific deps
        wasm.addPackage(tracylib.pkg);
        wasm.addPackage(utf8proc.pkg);
        _ = try utf8proc.link(b, wasm);

        const step = b.step("term-wasm", "Build the terminal.wasm library");
        step.dependOn(&wasm.step);
    }

    // Run
    {
        // Build our run step, which runs the main app by default, but will
        // run a conformance app if `-Dconformance` is set.
        const run_exe = if (conformance) |name| blk: {
            var conformance_exes = try conformanceSteps(b, target, mode);
            defer conformance_exes.deinit();
            break :blk conformance_exes.get(name) orelse return error.InvalidConformance;
        } else exe;
        const run_cmd = run_exe.run();
        run_cmd.step.dependOn(&run_exe.step);
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the app");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_step = b.step("test", "Run all tests");
        var test_filter = b.option([]const u8, "test-filter", "Filter for test");

        const main_test = b.addTestExe("ghostty-test", "src/main.zig");
        {
            if (emit_test_exe) main_test.install();
            const main_test_run = main_test.run();
            main_test.setFilter(test_filter);
            main_test.setTarget(target);
            try addDeps(b, main_test, true);
            main_test.addOptions("build_options", exe_options);

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{"ghostty"});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&main_test_run.step);
            test_step.dependOn(&after.step);
        }

        // Named package dependencies don't have their tests run by reference,
        // so we iterate through them here. We're only interested in dependencies
        // we wrote (are in the "pkg/" directory).
        for (main_test.packages.items) |pkg_| {
            const pkg: std.build.Pkg = pkg_;
            if (std.mem.eql(u8, pkg.name, "build_options")) continue;
            if (std.mem.eql(u8, pkg.name, "glfw")) continue;

            var buf: [256]u8 = undefined;
            var test_ = b.addTestExeSource(
                try std.fmt.bufPrint(&buf, "{s}-test", .{pkg.name}),
                pkg.source,
            );
            const test_run = test_.run();

            test_.setTarget(target);
            try addDeps(b, test_, true);
            if (pkg.dependencies) |children| {
                test_.packages = std.ArrayList(std.build.Pkg).init(b.allocator);
                try test_.packages.appendSlice(children);
            }

            var before = b.addLog("\x1b[" ++ color_map.get("cyan").? ++ "\x1b[" ++ color_map.get("b").? ++ "[{s} tests]" ++ "\x1b[" ++ color_map.get("d").? ++ " ----" ++ "\x1b[0m", .{pkg.name});
            var after = b.addLog("\x1b[" ++ color_map.get("d").? ++ "–––---\n\n" ++ "\x1b[0m", .{});
            test_step.dependOn(&before.step);
            test_step.dependOn(&test_run.step);
            test_step.dependOn(&after.step);

            if (emit_test_exe) test_.install();
        }
    }
}

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.build.Builder,
    step: *std.build.LibExeObjStep,
    static: bool,
) !void {
    // We always need the Zig packages
    if (enable_fontconfig) step.addPackage(fontconfig.pkg);
    step.addPackage(freetype.pkg);
    step.addPackage(harfbuzz.pkg);
    step.addPackage(glfw.pkg);
    step.addPackage(libuv.pkg);
    step.addPackage(utf8proc.pkg);

    // Mac Stuff
    if (step.target.isDarwin()) {
        step.addPackage(macos.pkg);
        _ = try macos.link(b, step, .{});
    }

    // We always statically compile glad
    step.addIncludePath("vendor/glad/include/");
    step.addCSourceFile("vendor/glad/src/gl.c", &.{});

    // Tracy
    step.addPackage(tracylib.pkg);
    if (tracy) {
        var tracy_step = try tracylib.link(b, step);
        system_sdk.include(b, tracy_step, .{});
    }

    // utf8proc
    _ = try utf8proc.link(b, step);

    // Glfw
    glfw.link(b, step, .{
        .metal = false,
        .opengl = false, // Found at runtime
    });

    // Dynamic link
    if (!static) {
        step.addIncludePath(freetype.include_path_self);
        step.linkSystemLibrary("bzip2");
        step.linkSystemLibrary("freetype2");
        step.linkSystemLibrary("harfbuzz");
        step.linkSystemLibrary("libpng");
        step.linkSystemLibrary("libuv");
        step.linkSystemLibrary("zlib");

        if (enable_fontconfig) step.linkSystemLibrary("fontconfig");
    }

    // Other dependencies, we may dynamically link
    if (static) {
        const zlib_step = try zlib.link(b, step);
        const libpng_step = try libpng.link(b, step, .{
            .zlib = .{
                .step = zlib_step,
                .include = &zlib.include_paths,
            },
        });

        // Freetype
        const freetype_step = try freetype.link(b, step, .{
            .libpng = freetype.Options.Libpng{
                .enabled = true,
                .step = libpng_step,
                .include = &libpng.include_paths,
            },

            .zlib = .{
                .enabled = true,
                .step = zlib_step,
                .include = &zlib.include_paths,
            },
        });

        // Harfbuzz
        _ = try harfbuzz.link(b, step, .{
            .freetype = .{
                .enabled = true,
                .step = freetype_step,
                .include = &freetype.include_paths,
            },
        });

        // Libuv
        const libuv_step = try libuv.link(b, step);
        system_sdk.include(b, libuv_step, .{});

        // Only Linux gets fontconfig
        if (enable_fontconfig) {
            // Libxml2
            const libxml2_lib = try libxml2.create(
                b,
                step.target,
                step.build_mode,
                .{ .lzma = false, .zlib = false },
            );
            libxml2_lib.link(step);

            // Fontconfig
            const fontconfig_step = try fontconfig.link(b, step, .{
                .freetype = .{
                    .enabled = true,
                    .step = freetype_step,
                    .include = &freetype.include_paths,
                },

                .libxml2 = true,
            });
            libxml2_lib.link(fontconfig_step);
        }
    }
}

fn conformanceSteps(
    b: *std.build.Builder,
    target: std.zig.CrossTarget,
    mode: std.builtin.Mode,
) !std.StringHashMap(*LibExeObjStep) {
    var map = std.StringHashMap(*LibExeObjStep).init(b.allocator);

    // Open the directory ./conformance
    const c_dir_path = (comptime root()) ++ "/conformance";
    var c_dir = try fs.openIterableDirAbsolute(c_dir_path, .{});
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // Executable builder.
        const c_exe = b.addExecutable(name, path);
        c_exe.setTarget(target);
        c_exe.setBuildMode(mode);

        // Store the mapping
        try map.put(name, c_exe);
    }

    return map;
}

/// Path to the directory with the build.zig.
fn root() []const u8 {
    return std.fs.path.dirname(@src().file) orelse unreachable;
}

/// ANSI escape codes for colored log output
const color_map = std.ComptimeStringMap([]const u8, .{
    &.{ "black", "30m" },
    &.{ "blue", "34m" },
    &.{ "b", "1m" },
    &.{ "d", "2m" },
    &.{ "cyan", "36m" },
    &.{ "green", "32m" },
    &.{ "magenta", "35m" },
    &.{ "red", "31m" },
    &.{ "white", "37m" },
    &.{ "yellow", "33m" },
});
