const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const LibExeObjStep = std.build.LibExeObjStep;
const RunStep = std.build.RunStep;

const apprt = @import("src/apprt.zig");
const font = @import("src/font/main.zig");
const renderer = @import("src/renderer.zig");
const terminfo = @import("src/terminfo/main.zig");
const WasmTarget = @import("src/os/wasm/target.zig").Target;
const LibtoolStep = @import("src/build/LibtoolStep.zig");
const LipoStep = @import("src/build/LipoStep.zig");
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");
const Version = @import("src/build/Version.zig");

// Do a comptime Zig version requirement. The required Zig version is
// somewhat arbitrary: it is meant to be a version that we feel works well,
// but we liberally update it. In the future, we'll be more careful about
// using released versions so that package managers can integrate better.
comptime {
    const required_zig = "0.12.0-dev.983+78f2ae7f2";
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the minimum build requirement of v{}",
            .{ current_zig, min_zig },
        ));
    }
}

/// The version of the next release.
const app_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

/// Build options, see the build options help for more info.
var tracy: bool = false;
var flatpak: bool = false;
var app_runtime: apprt.Runtime = .none;
var renderer_impl: renderer.Impl = .opengl;
var font_backend: font.Backend = .freetype;

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        if (result.isDarwin()) {
            if (result.os_version_min == null) {
                result.os_version_min = .{ .semver = .{ .major = 12, .minor = 0, .patch = 0 } };
            }
        }

        break :target result;
    };

    const wasm_target: WasmTarget = .browser;

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    // Note: Our tracy usage has a huge memory leak currently so only enable
    // this if you really want tracy integration and don't mind the memory leak.
    // Or, please contribute a fix because I don't know where it is.
    tracy = b.option(
        bool,
        "tracy",
        "Enable Tracy integration (default true in Debug on Linux)",
    ) orelse false;

    flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;

    font_backend = b.option(
        font.Backend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse font.Backend.default(target, wasm_target);

    app_runtime = b.option(
        apprt.Runtime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse apprt.Runtime.default(target);

    renderer_impl = b.option(
        renderer.Impl,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse renderer.Impl.default(target, wasm_target);

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
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    const emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    // On NixOS, the built binary from `zig build` needs to patch the rpath
    // into the built binary for it to be portable across the NixOS system
    // it was built for. We default this to true if we can detect we're in
    // a Nix shell and have LD_LIBRARY_PATH set.
    const patch_rpath: ?[]const u8 = b.option(
        []const u8,
        "patch-rpath",
        "Inject the LD_LIBRARY_PATH as the rpath in the built binary. " ++
            "This defaults to LD_LIBRARY_PATH if we're in a Nix shell environment on NixOS.",
    ) orelse patch_rpath: {
        // We only do the patching if we're targeting our own CPU and its Linux.
        if (!target.isLinux() or !target.isNativeCpu()) break :patch_rpath null;

        // If we're in a nix shell we default to doing this.
        // Note: we purposely never deinit envmap because we leak the strings
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath null;
        break :patch_rpath env.get("LD_LIBRARY_PATH");
    };

    var version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    var version: std.SemanticVersion = if (version_string) |v|
        try std.SemanticVersion.parse(v)
    else version: {
        const vsn = try Version.detect(b);
        if (vsn.tag) |tag| {
            // Tip releases behave just like any other pre-release so we skip.
            if (!std.mem.eql(u8, tag, "tip")) {
                const expected = b.fmt("v{d}.{d}.{d}", .{
                    app_version.major,
                    app_version.minor,
                    app_version.patch,
                });

                if (!std.mem.eql(u8, tag, expected)) {
                    @panic("tagged releases must be in vX.Y.Z format matching build.zig");
                }

                break :version .{
                    .major = app_version.major,
                    .minor = app_version.minor,
                    .patch = app_version.patch,
                };
            }
        }

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = vsn.branch,
            .build = vsn.short_hash,
        };
    };

    // We can use wasmtime to test wasm
    b.enable_wasmtime = true;

    // Add our benchmarks
    try benchSteps(b, target, optimize, emit_bench);

    // We only build an exe if we have a runtime set.
    const exe_: ?*std.Build.Step.Compile = if (app_runtime != .none) b.addExecutable(.{
        .name = "ghostty",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    }) else null;

    const exe_options = b.addOptions();
    exe_options.addOption(std.SemanticVersion, "app_version", version);
    exe_options.addOption([:0]const u8, "app_version_string", try std.fmt.allocPrintZ(
        b.allocator,
        "{}",
        .{version},
    ));
    exe_options.addOption(bool, "tracy_enabled", tracy);
    exe_options.addOption(bool, "flatpak", flatpak);
    exe_options.addOption(apprt.Runtime, "app_runtime", app_runtime);
    exe_options.addOption(font.Backend, "font_backend", font_backend);
    exe_options.addOption(renderer.Impl, "renderer", renderer_impl);

    // Exe
    if (exe_) |exe| {
        exe.addOptions("build_options", exe_options);

        // Add the shared dependencies
        _ = try addDeps(b, exe, static);

        // If we're in NixOS but not in the shell environment then we issue
        // a warning because the rpath may not be setup properly.
        const is_nixos = is_nixos: {
            if (!target.isLinux()) break :is_nixos false;
            if (!target.isNativeCpu()) break :is_nixos false;
            if (target.getOsTag() != builtin.os.tag) break :is_nixos false;
            break :is_nixos if (std.fs.accessAbsolute("/etc/NIXOS", .{})) true else |_| false;
        };
        if (is_nixos and env.get("IN_NIX_SHELL") == null) {
            try exe.step.addError(
                "\x1b[" ++ color_map.get("yellow").? ++
                    "\x1b[" ++ color_map.get("d").? ++
                    \\Detected building on and for NixOS outside of the Nix shell environment.
                    \\
                    \\The resulting ghostty binary will likely fail on launch because it is
                    \\unable to dynamically load the windowing libs (X11, Wayland, etc.).
                    \\We highly recommend running only within the Nix build environment
                    \\and the resulting binary will be portable across your system.
                    \\
                    \\To run in the Nix build environment, use the following command.
                    \\Append any additional options like (`-Doptimize` flags). The resulting
                    \\binary will be in zig-out as usual.
                    \\
                    \\  nix develop -c zig build
                    \\
                    ++
                    "\x1b[0m",
                .{},
            );
        }

        // If we're installing, we get the install step so we can add
        // additional dependencies to it.
        const install_step = if (app_runtime != .none) step: {
            const step = b.addInstallArtifact(exe, .{});
            b.getInstallStep().dependOn(&step.step);
            break :step step;
        } else null;

        // Patch our rpath if that option is specified.
        if (patch_rpath) |rpath| {
            if (rpath.len > 0) {
                const run = RunStep.create(b, "patchelf rpath");
                run.addArgs(&.{ "patchelf", "--set-rpath", rpath });
                run.addArtifactArg(exe);

                if (install_step) |step| {
                    step.step.dependOn(&run.step);
                }
            }
        }

        // App (Mac)
        if (target.isDarwin()) {
            const bin_install = b.addInstallFile(
                exe.getEmittedBin(),
                "Ghostty.app/Contents/MacOS/ghostty",
            );
            b.getInstallStep().dependOn(&bin_install.step);
            b.installFile("dist/macos/Info.plist", "Ghostty.app/Contents/Info.plist");
            b.installFile("dist/macos/Ghostty.icns", "Ghostty.app/Contents/Resources/Ghostty.icns");
        }
    }

    // Shell-integration
    {
        const install = b.addInstallDirectory(.{
            .source_dir = .{ .path = "src/shell-integration" },
            .install_dir = .{ .custom = "share" },
            .install_subdir = "shell-integration",
            .exclude_extensions = &.{".md"},
        });
        b.getInstallStep().dependOn(&install.step);

        if (target.isDarwin() and exe_ != null) {
            const mac_install = b.addInstallDirectory(options: {
                var copy = install.options;
                copy.install_dir = .{
                    .custom = "Ghostty.app/Contents/Resources",
                };
                break :options copy;
            });
            b.getInstallStep().dependOn(&mac_install.step);
        }
    }

    // Terminfo
    {
        // Encode our terminfo
        var str = std.ArrayList(u8).init(b.allocator);
        defer str.deinit();
        try terminfo.ghostty.encode(str.writer());

        // Write it
        var wf = b.addWriteFiles();
        const src_source = wf.add("share/terminfo/ghostty.terminfo", str.items);
        const src_install = b.addInstallFile(src_source, "share/terminfo/ghostty.terminfo");
        b.getInstallStep().dependOn(&src_install.step);
        if (target.isDarwin() and exe_ != null) {
            const mac_src_install = b.addInstallFile(
                src_source,
                "Ghostty.app/Contents/Resources/terminfo/ghostty.terminfo",
            );
            b.getInstallStep().dependOn(&mac_src_install.step);
        }

        // Convert to termcap source format if thats helpful to people and
        // install it. The resulting value here is the termcap source in case
        // that is used for other commands.
        if (!target.isWindows()) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileSourceArg(src_source);
            const out_source = run_step.captureStdOut();
            _ = run_step.captureStdErr(); // so we don't see stderr

            const cap_install = b.addInstallFile(out_source, "share/terminfo/ghostty.termcap");
            b.getInstallStep().dependOn(&cap_install.step);

            if (target.isDarwin() and exe_ != null) {
                const mac_cap_install = b.addInstallFile(
                    out_source,
                    "Ghostty.app/Contents/Resources/terminfo/ghostty.termcap",
                );
                b.getInstallStep().dependOn(&mac_cap_install.step);
            }
        }

        // Compile the terminfo source into a terminfo database
        if (!target.isWindows()) {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg("terminfo");
            run_step.addFileSourceArg(src_source);
            _ = run_step.captureStdErr(); // so we don't see stderr

            // Depend on the terminfo source install step so that Zig build
            // creates the "share" directory for us.
            run_step.step.dependOn(&src_install.step);

            {
                const copy_step = RunStep.create(b, "copy terminfo db");
                copy_step.addArgs(&.{ "cp", "-R" });
                copy_step.addFileSourceArg(path);
                copy_step.addArg(b.fmt("{s}/share", .{b.install_prefix}));
                b.getInstallStep().dependOn(&copy_step.step);
            }

            if (target.isDarwin() and exe_ != null) {
                const copy_step = RunStep.create(b, "copy terminfo db");
                copy_step.addArgs(&.{ "cp", "-R" });
                copy_step.addFileSourceArg(path);
                copy_step.addArg(
                    b.fmt("{s}/Ghostty.app/Contents/Resources", .{b.install_prefix}),
                );
                b.getInstallStep().dependOn(&copy_step.step);
            }
        }
    }

    // App (Linux)
    if (target.isLinux()) {
        // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

        // Desktop file so that we have an icon and other metadata
        if (flatpak) {
            b.installFile("dist/linux/app-flatpak.desktop", "share/applications/com.mitchellh.ghostty.desktop");
        } else {
            b.installFile("dist/linux/app.desktop", "share/applications/com.mitchellh.ghostty.desktop");
        }

        // Various icons that our application can use, including the icon
        // that will be used for the desktop.
        b.installFile("images/icons/icon_16x16.png", "share/icons/hicolor/16x16/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_32x32.png", "share/icons/hicolor/32x32/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_128x128.png", "share/icons/hicolor/128x128/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_256x256.png", "share/icons/hicolor/256x256/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_512x512.png", "share/icons/hicolor/512x512/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_16x16@2x@2x.png", "share/icons/hicolor/16x16@2/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_32x32@2x@2x.png", "share/icons/hicolor/32x32@2/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_128x128@2x@2x.png", "share/icons/hicolor/128x128@2/apps/com.mitchellh.ghostty.png");
        b.installFile("images/icons/icon_256x256@2x@2x.png", "share/icons/hicolor/256x256@2/apps/com.mitchellh.ghostty.png");
    }

    // On Mac we can build the embedding library.
    if (builtin.target.isDarwin() and target.isDarwin()) {
        const static_lib_aarch64 = lib: {
            const lib = b.addStaticLibrary(.{
                .name = "ghostty",
                .root_source_file = .{ .path = "src/main_c.zig" },
                .target = .{
                    .cpu_arch = .aarch64,
                    .os_tag = .macos,
                    .os_version_min = target.os_version_min,
                },
                .optimize = optimize,
            });
            lib.bundle_compiler_rt = true;
            lib.linkLibC();
            lib.addOptions("build_options", exe_options);

            // Create a single static lib with all our dependencies merged
            var lib_list = try addDeps(b, lib, true);
            try lib_list.append(lib.getEmittedBin());
            const libtool = LibtoolStep.create(b, .{
                .name = "ghostty",
                .out_name = "libghostty-aarch64-fat.a",
                .sources = lib_list.items,
            });
            libtool.step.dependOn(&lib.step);
            b.default_step.dependOn(libtool.step);

            break :lib libtool;
        };

        const static_lib_x86_64 = lib: {
            const lib = b.addStaticLibrary(.{
                .name = "ghostty",
                .root_source_file = .{ .path = "src/main_c.zig" },
                .target = .{
                    .cpu_arch = .x86_64,
                    .os_tag = .macos,
                    .os_version_min = target.os_version_min,
                },
                .optimize = optimize,
            });
            lib.bundle_compiler_rt = true;
            lib.linkLibC();
            lib.addOptions("build_options", exe_options);

            // Create a single static lib with all our dependencies merged
            var lib_list = try addDeps(b, lib, true);
            try lib_list.append(lib.getEmittedBin());
            const libtool = LibtoolStep.create(b, .{
                .name = "ghostty",
                .out_name = "libghostty-x86_64-fat.a",
                .sources = lib_list.items,
            });
            libtool.step.dependOn(&lib.step);
            b.default_step.dependOn(libtool.step);

            break :lib libtool;
        };

        const static_lib_universal = LipoStep.create(b, .{
            .name = "ghostty",
            .out_name = "libghostty.a",
            .input_a = static_lib_aarch64.output,
            .input_b = static_lib_x86_64.output,
        });
        static_lib_universal.step.dependOn(static_lib_aarch64.step);
        static_lib_universal.step.dependOn(static_lib_x86_64.step);

        // Add our library to zig-out
        const lib_install = b.addInstallLibFile(
            static_lib_universal.output,
            "libghostty.a",
        );
        b.getInstallStep().dependOn(&lib_install.step);

        // Copy our ghostty.h to include
        const header_install = b.addInstallHeaderFile(
            "include/ghostty.h",
            "ghostty.h",
        );
        b.getInstallStep().dependOn(&header_install.step);

        // The xcframework wraps our ghostty library so that we can link
        // it to the final app built with Swift.
        const xcframework = XCFrameworkStep.create(b, .{
            .name = "GhosttyKit",
            .out_path = "macos/GhosttyKit.xcframework",
            .library = static_lib_universal.output,
            .headers = .{ .path = "include" },
        });
        xcframework.step.dependOn(static_lib_universal.step);
        b.default_step.dependOn(xcframework.step);
    }

    // wasm
    {
        // Build our Wasm target.
        const wasm_crosstarget: std.zig.CrossTarget = .{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
            .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
            .cpu_features_add = std.Target.wasm.featureSet(&.{
                // We use this to explicitly request shared memory.
                .atomics,

                // Not explicitly used but compiler could use them if they want.
                .bulk_memory,
                .reference_types,
                .sign_ext,
            }),
        };

        // Whether we're using wasm shared memory. Some behaviors change.
        // For now we require this but I wanted to make the code handle both
        // up front.
        const wasm_shared: bool = true;
        exe_options.addOption(bool, "wasm_shared", wasm_shared);

        // We want to support alternate wasm targets in the future (i.e.
        // server side) so we have this now although its hardcoded.
        exe_options.addOption(WasmTarget, "wasm_target", wasm_target);

        const wasm = b.addSharedLibrary(.{
            .name = "ghostty-wasm",
            .root_source_file = .{ .path = "src/main_wasm.zig" },
            .target = wasm_crosstarget,
            .optimize = optimize,
        });
        wasm.addOptions("build_options", exe_options);

        // So that we can use web workers with our wasm binary
        wasm.import_memory = true;
        wasm.initial_memory = 65536 * 25;
        wasm.max_memory = 65536 * 65536; // Maximum number of pages in wasm32
        wasm.shared_memory = wasm_shared;

        // Stack protector adds extern requirements that we don't satisfy.
        wasm.stack_protector = false;

        // Wasm-specific deps
        _ = try addDeps(b, wasm, true);

        // Install
        const wasm_install = b.addInstallArtifact(wasm, .{});
        wasm_install.dest_dir = .{ .prefix = {} };

        const step = b.step("wasm", "Build the wasm library");
        step.dependOn(&wasm_install.step);

        // We support tests via wasmtime. wasmtime uses WASI so this
        // isn't an exact match to our freestanding target above but
        // it lets us test some basic functionality.
        const test_step = b.step("test-wasm", "Run all tests for wasm");
        const main_test = b.addTest(.{
            .name = "wasm-test",
            .root_source_file = .{ .path = "src/main_wasm.zig" },
            .target = wasm_crosstarget,
        });
        main_test.addOptions("build_options", exe_options);
        _ = try addDeps(b, main_test, true);
        test_step.dependOn(&main_test.step);
    }

    // Run
    run: {
        // Build our run step, which runs the main app by default, but will
        // run a conformance app if `-Dconformance` is set.
        const run_exe = if (conformance) |name| blk: {
            var conformance_exes = try conformanceSteps(b, target, optimize);
            defer conformance_exes.deinit();
            break :blk conformance_exes.get(name) orelse return error.InvalidConformance;
        } else exe_ orelse break :run;

        const run_cmd = b.addRunArtifact(run_exe);
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

        const main_test = b.addTest(.{
            .name = "ghostty-test",
            .root_source_file = .{ .path = "src/main.zig" },
            .target = target,
            .filter = test_filter,
        });
        {
            if (emit_test_exe) b.installArtifact(main_test);
            _ = try addDeps(b, main_test, true);
            main_test.addOptions("build_options", exe_options);

            const test_run = b.addRunArtifact(main_test);
            test_step.dependOn(&test_run.step);
        }
    }
}

/// Used to keep track of a list of file sources.
const FileSourceList = std.ArrayList(std.build.FileSource);

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.Build,
    step: *std.build.LibExeObjStep,
    static: bool,
) !FileSourceList {
    var static_libs = FileSourceList.init(b.allocator);
    errdefer static_libs.deinit();

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.build.Step.Compile.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .Dynamic,
        .search_strategy = .mode_first,
    };

    // Dependencies
    const cimgui_dep = b.dependency("cimgui", .{ .target = step.target, .optimize = step.optimize });
    const js_dep = b.dependency("zig_js", .{ .target = step.target, .optimize = step.optimize });
    const libxev_dep = b.dependency("libxev", .{ .target = step.target, .optimize = step.optimize });
    const objc_dep = b.dependency("zig_objc", .{ .target = step.target, .optimize = step.optimize });

    const fontconfig_dep = b.dependency("fontconfig", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const freetype_dep = b.dependency("freetype", .{
        .target = step.target,
        .optimize = step.optimize,
        .@"enable-libpng" = true,
    });
    const mach_glfw_dep = b.dependency("mach_glfw", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const libpng_dep = b.dependency("libpng", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const macos_dep = b.dependency("macos", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const pixman_dep = b.dependency("pixman", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const tracy_dep = b.dependency("tracy", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const zlib_dep = b.dependency("zlib", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const utf8proc_dep = b.dependency("utf8proc", .{
        .target = step.target,
        .optimize = step.optimize,
    });
    const harfbuzz_dep = b.dependency("harfbuzz", .{
        .target = step.target,
        .optimize = step.optimize,
        .@"enable-freetype" = true,
        .@"enable-coretext" = font_backend.hasCoretext(),
    });

    // Wasm we do manually since it is such a different build.
    if (step.target.getCpuArch() == .wasm32) {
        // We link this package but its a no-op since Tracy
        // never actually WORKS with wasm.
        step.addModule("tracy", tracy_dep.module("tracy"));
        step.addModule("utf8proc", utf8proc_dep.module("utf8proc"));
        step.addModule("zig-js", js_dep.module("zig-js"));

        // utf8proc
        step.linkLibrary(utf8proc_dep.artifact("utf8proc"));

        return static_libs;
    }

    // On Linux, we need to add a couple common library paths that aren't
    // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
    // on x86_64.
    if (step.target.isLinux()) {
        const triple = try step.target.linuxTriple(b.allocator);
        step.addLibraryPath(.{ .path = b.fmt("/usr/lib/{s}", .{triple}) });
    }

    // C files
    step.linkLibC();
    step.addIncludePath(.{ .path = "src/stb" });
    step.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });

    // If we're building a lib we have some different deps
    const lib = step.kind == .lib;

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    try addSystemSDK(b, step);

    // We always need the Zig packages
    // TODO: This can't be the right way to use the new Zig modules system,
    // so take a closer look at this again later.
    if (font_backend.hasFontconfig()) step.addModule(
        "fontconfig",
        fontconfig_dep.module("fontconfig"),
    );
    step.addModule("freetype", freetype_dep.module("freetype"));
    step.addModule("harfbuzz", harfbuzz_dep.module("harfbuzz"));
    step.addModule("xev", libxev_dep.module("xev"));
    step.addModule("pixman", pixman_dep.module("pixman"));
    step.addModule("utf8proc", utf8proc_dep.module("utf8proc"));

    // Mac Stuff
    if (step.target.isDarwin()) {
        step.addModule("objc", objc_dep.module("objc"));
        step.addModule("macos", macos_dep.module("macos"));
        step.linkLibrary(macos_dep.artifact("macos"));
        try static_libs.append(macos_dep.artifact("macos").getEmittedBin());
    }

    // cimgui
    step.addModule("cimgui", cimgui_dep.module("cimgui"));
    step.linkLibrary(cimgui_dep.artifact("cimgui"));
    try static_libs.append(cimgui_dep.artifact("cimgui").getEmittedBin());

    // Tracy
    step.addModule("tracy", tracy_dep.module("tracy"));
    if (tracy) {
        step.linkLibrary(tracy_dep.artifact("tracy"));
        try static_libs.append(tracy_dep.artifact("tracy").getEmittedBin());
    }

    // utf8proc
    step.linkLibrary(utf8proc_dep.artifact("utf8proc"));
    try static_libs.append(utf8proc_dep.artifact("utf8proc").getEmittedBin());

    // Dynamic link
    if (!static) {
        step.addIncludePath(freetype_dep.path(""));
        step.linkSystemLibrary2("bzip2", dynamic_link_opts);
        step.linkSystemLibrary2("freetype2", dynamic_link_opts);
        step.linkSystemLibrary2("harfbuzz", dynamic_link_opts);
        step.linkSystemLibrary2("libpng", dynamic_link_opts);
        step.linkSystemLibrary2("pixman-1", dynamic_link_opts);
        step.linkSystemLibrary2("zlib", dynamic_link_opts);

        if (font_backend.hasFontconfig()) {
            step.linkSystemLibrary2("fontconfig", dynamic_link_opts);
        }
    }

    // Other dependencies, we may dynamically link
    if (static) {
        step.linkLibrary(zlib_dep.artifact("z"));
        try static_libs.append(zlib_dep.artifact("z").getEmittedBin());

        step.linkLibrary(libpng_dep.artifact("png"));
        try static_libs.append(libpng_dep.artifact("png").getEmittedBin());

        // Freetype
        step.linkLibrary(freetype_dep.artifact("freetype"));
        try static_libs.append(freetype_dep.artifact("freetype").getEmittedBin());

        // Harfbuzz
        step.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
        try static_libs.append(harfbuzz_dep.artifact("harfbuzz").getEmittedBin());

        // Pixman
        step.linkLibrary(pixman_dep.artifact("pixman"));
        try static_libs.append(pixman_dep.artifact("pixman").getEmittedBin());

        // Only Linux gets fontconfig
        if (font_backend.hasFontconfig()) {
            // Fontconfig
            step.linkLibrary(fontconfig_dep.artifact("fontconfig"));
        }
    }

    if (!lib) {
        // We always statically compile glad
        step.addIncludePath(.{ .path = "vendor/glad/include/" });
        step.addCSourceFile(.{
            .file = .{ .path = "vendor/glad/src/gl.c" },
            .flags = &.{},
        });

        // When we're targeting flatpak we ALWAYS link GTK so we
        // get access to glib for dbus.
        if (flatpak) step.linkSystemLibrary2("gtk4", dynamic_link_opts);

        switch (app_runtime) {
            .none => {},

            .glfw => {
                const glfw_dep = b.dependency("glfw", .{
                    .target = step.target,
                    .optimize = step.optimize,
                    .x11 = step.target.isLinux(),
                    .wayland = step.target.isLinux(),
                    .metal = step.target.isDarwin(),
                });

                step.addModule("glfw", mach_glfw_dep.module("mach-glfw"));
                step.linkLibrary(mach_glfw_dep.artifact("mach-glfw"));
                step.linkLibrary(glfw_dep.artifact("glfw"));
            },

            .gtk => {
                step.linkSystemLibrary2("gtk4", dynamic_link_opts);
                step.linkSystemLibrary2("adwaita-1", dynamic_link_opts);
            },
        }
    }

    return static_libs;
}

/// Adds the proper system headers for the target.
fn addSystemSDK(
    b: *std.Build,
    step: *std.Build.CompileStep,
) !void {
    if (step.target.isDarwin()) {
        try @import("apple_sdk").addPaths(b, step);
    }

    if (step.target.isLinux()) {
        step.linkLibrary(b.dependency("x11_headers", .{
            .target = step.target,
            .optimize = step.optimize,
        }).artifact("x11-headers"));
    }

    // GLFW requires these on all platforms so we just add them here. It
    // doesn't hurt to add them if we don't use GLFW since they're all
    // namespaced.
    step.linkLibrary(b.dependency("vulkan_headers", .{
        .target = step.target,
        .optimize = step.optimize,
    }).artifact("vulkan-headers"));
}

fn benchSteps(
    b: *std.Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
    install: bool,
) !void {
    // Open the directory ./src/bench
    const c_dir_path = (comptime root()) ++ "/src/bench";
    var c_dir = try fs.openIterableDirAbsolute(c_dir_path, .{});
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // If it doesn't end in 'zig' then ignore
        if (!std.mem.eql(u8, entry.name[index + 1 ..], "zig")) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = entry.name[0..index];
        const path = try fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // Executable builder.
        const bin_name = try std.fmt.allocPrint(b.allocator, "bench-{s}", .{name});
        const c_exe = b.addExecutable(.{
            .name = bin_name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = optimize,
            .main_pkg_path = .{ .path = "./src" },
        });
        if (install) b.installArtifact(c_exe);
        _ = try addDeps(b, c_exe, true);
    }
}

fn conformanceSteps(
    b: *std.Build,
    target: std.zig.CrossTarget,
    optimize: std.builtin.Mode,
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
        const c_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = .{ .path = path },
            .target = target,
            .optimize = optimize,
        });

        const install = b.addInstallArtifact(c_exe, .{});
        install.dest_sub_path = "conformance";
        b.getInstallStep().dependOn(&install.step);

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
