const std = @import("std");
const builtin = @import("builtin");
const fs = std.fs;
const CompileStep = std.Build.Step.Compile;
const RunStep = std.Build.Step.Run;
const ResolvedTarget = std.Build.ResolvedTarget;

const apprt = @import("src/apprt.zig");
const font = @import("src/font/main.zig");
const renderer = @import("src/renderer.zig");
const terminfo = @import("src/terminfo/main.zig");
const config_vim = @import("src/config/vim.zig");
const fish_completions = @import("src/build/fish_completions.zig");
const build_config = @import("src/build_config.zig");
const BuildConfig = build_config.BuildConfig;
const WasmTarget = @import("src/os/wasm/target.zig").Target;
const LibtoolStep = @import("src/build/LibtoolStep.zig");
const LipoStep = @import("src/build/LipoStep.zig");
const MetallibStep = @import("src/build/MetallibStep.zig");
const XCFrameworkStep = @import("src/build/XCFrameworkStep.zig");
const Version = @import("src/build/Version.zig");
const Command = @import("src/Command.zig");

comptime {
    // This is the required Zig version for building this project. We allow
    // any patch version but the major and minor must match exactly.
    const required_zig = "0.13.0";

    // Fail compilation if the current Zig version doesn't meet requirements.
    const current_vsn = builtin.zig_version;
    const required_vsn = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_vsn.major != required_vsn.major or
        current_vsn.minor != required_vsn.minor)
    {
        @compileError(std.fmt.comptimePrint(
            "Your Zig version v{} does not meet the required build version of v{}",
            .{ current_vsn, required_vsn },
        ));
    }
}

/// The version of the next release.
const app_version = std.SemanticVersion{ .major = 0, .minor = 1, .patch = 0 };

pub fn build(b: *std.Build) !void {
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // If we have no minimum OS version, we set the default based on
        // our tag. Not all tags have a minimum so this may be null.
        if (result.query.os_version_min == null) {
            result.query.os_version_min = osVersionMin(result.result.os.tag);
        }

        break :target result;
    };

    const wasm_target: WasmTarget = .browser;

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    defer env.deinit();

    // Our build configuration. This is all on a struct so that we can easily
    // modify it for specific build types (for example, wasm we strictly
    // control our backends).
    var config: BuildConfig = .{};

    config.flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;

    config.font_backend = b.option(
        font.Backend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse font.Backend.default(target.result, wasm_target);

    config.app_runtime = b.option(
        apprt.Runtime,
        "app-runtime",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse apprt.Runtime.default(target.result);

    config.renderer = b.option(
        renderer.Impl,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse renderer.Impl.default(target.result, wasm_target);

    config.libadwaita = b.option(
        bool,
        "gtk-libadwaita",
        "Enables the use of libadwaita when using the gtk rendering backend.",
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

    const emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    const emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (emit_bench or emit_test_exe or emit_helpgen) break :emit_docs false;

        // We only default to true if we can find pandoc.
        const path = Command.expandPath(b.allocator, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    const emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse builtin.target.isDarwin() and
        target.result.os.tag == .macos and
        config.app_runtime == .none and
        (!emit_bench and !emit_test_exe and !emit_helpgen);

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
        if (!(target.result.os.tag == .linux) or !target.query.isNativeCpu()) break :patch_rpath null;

        // If we're in a nix shell we default to doing this.
        // Note: we purposely never deinit envmap because we leak the strings
        if (env.get("IN_NIX_SHELL") == null) break :patch_rpath null;
        break :patch_rpath env.get("LD_LIBRARY_PATH");
    };

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        try std.SemanticVersion.parse(v)
    else version: {
        const vsn = Version.detect(b) catch |err| switch (err) {
            // If Git isn't available we just make an unknown dev version.
            error.GitNotFound,
            error.GitNotRepository,
            => break :version .{
                .major = app_version.major,
                .minor = app_version.minor,
                .patch = app_version.patch,
                .pre = "dev",
                .build = "0000000",
            },

            else => return err,
        };
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

    // These are all our dependencies that can be used with system
    // packages if they exist. We set them up here so that we can set
    // their defaults early. The first call configures the integration and
    // subsequent calls just return the configured value.
    {
        // These dependencies we want to default false if we're on macOS.
        // On macOS we don't want to use system libraries because we
        // generally want a fat binary. This can be overridden with the
        // `-fsys` flag.
        for (&[_][]const u8{
            "freetype",
            "harfbuzz",
            "fontconfig",
            "libpng",
            "zlib",
            "oniguruma",
        }) |dep| {
            _ = b.systemIntegrationOption(
                dep,
                .{
                    // If we're not on darwin we want to use whatever the
                    // default is via the system package mode
                    .default = if (target.result.isDarwin()) false else null,
                },
            );
        }

        // These default to false because they're rarely available as
        // system packages so we usually want to statically link them.
        for (&[_][]const u8{
            "glslang",
            "spirv-cross",
            "simdutf",
        }) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = false });
        }
    }

    // We can use wasmtime to test wasm
    b.enable_wasmtime = true;

    // Help exe. This must be run before any dependent executables because
    // otherwise the build will be cached without emit. That's clunky but meh.
    if (emit_helpgen) try addHelp(b, null, config);

    // Add our benchmarks
    try benchSteps(b, target, config, emit_bench);

    // We only build an exe if we have a runtime set.
    const exe_: ?*std.Build.Step.Compile = if (config.app_runtime != .none) b.addExecutable(.{
        .name = "ghostty",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = switch (optimize) {
            .Debug => false,
            .ReleaseSafe => false,
            .ReleaseFast, .ReleaseSmall => true,
        },
    }) else null;

    // Exe
    if (exe_) |exe| {
        // Add the shared dependencies
        _ = try addDeps(b, exe, config);

        // If we're in NixOS but not in the shell environment then we issue
        // a warning because the rpath may not be setup properly.
        const is_nixos = is_nixos: {
            if (target.result.os.tag != .linux) break :is_nixos false;
            if (!target.query.isNativeCpu()) break :is_nixos false;
            if (!target.query.isNativeOs()) break :is_nixos false;
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

        if (target.result.os.tag == .windows) {
            exe.subsystem = .Windows;
            exe.addWin32ResourceFile(.{
                .file = b.path("dist/windows/ghostty.rc"),
            });
        }

        // If we're installing, we get the install step so we can add
        // additional dependencies to it.
        const install_step = if (config.app_runtime != .none) step: {
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
        if (target.result.os.tag == .macos) {
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
            .source_dir = b.path("src/shell-integration"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "shell-integration" }),
            .exclude_extensions = &.{".md"},
        });
        b.getInstallStep().dependOn(&install.step);

        if (target.result.os.tag == .macos and exe_ != null) {
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

    // Themes
    {
        const upstream = b.dependency("iterm2_themes", .{});
        const install = b.addInstallDirectory(.{
            .source_dir = upstream.path("ghostty"),
            .install_dir = .{ .custom = "share" },
            .install_subdir = b.pathJoin(&.{ "ghostty", "themes" }),
            .exclude_extensions = &.{".md"},
        });
        b.getInstallStep().dependOn(&install.step);

        if (target.result.os.tag == .macos and exe_ != null) {
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
        if (target.result.os.tag == .macos and exe_ != null) {
            const mac_src_install = b.addInstallFile(
                src_source,
                "Ghostty.app/Contents/Resources/terminfo/ghostty.terminfo",
            );
            b.getInstallStep().dependOn(&mac_src_install.step);
        }

        // Convert to termcap source format if thats helpful to people and
        // install it. The resulting value here is the termcap source in case
        // that is used for other commands.
        if (target.result.os.tag != .windows) {
            const run_step = RunStep.create(b, "infotocap");
            run_step.addArg("infotocap");
            run_step.addFileArg(src_source);
            const out_source = run_step.captureStdOut();
            _ = run_step.captureStdErr(); // so we don't see stderr

            const cap_install = b.addInstallFile(out_source, "share/terminfo/ghostty.termcap");
            b.getInstallStep().dependOn(&cap_install.step);

            if (target.result.os.tag == .macos and exe_ != null) {
                const mac_cap_install = b.addInstallFile(
                    out_source,
                    "Ghostty.app/Contents/Resources/terminfo/ghostty.termcap",
                );
                b.getInstallStep().dependOn(&mac_cap_install.step);
            }
        }

        // Compile the terminfo source into a terminfo database
        if (target.result.os.tag != .windows) {
            const run_step = RunStep.create(b, "tic");
            run_step.addArgs(&.{ "tic", "-x", "-o" });
            const path = run_step.addOutputFileArg("terminfo");
            run_step.addFileArg(src_source);
            _ = run_step.captureStdErr(); // so we don't see stderr

            // Depend on the terminfo source install step so that Zig build
            // creates the "share" directory for us.
            run_step.step.dependOn(&src_install.step);

            {
                const copy_step = RunStep.create(b, "copy terminfo db");
                copy_step.addArgs(&.{ "cp", "-R" });
                copy_step.addFileArg(path);
                copy_step.addArg(b.fmt("{s}/share", .{b.install_prefix}));
                b.getInstallStep().dependOn(&copy_step.step);
            }

            if (target.result.os.tag == .macos and exe_ != null) {
                const copy_step = RunStep.create(b, "copy terminfo db");
                copy_step.addArgs(&.{ "cp", "-R" });
                copy_step.addFileArg(path);
                copy_step.addArg(
                    b.fmt("{s}/Ghostty.app/Contents/Resources", .{b.install_prefix}),
                );
                b.getInstallStep().dependOn(&copy_step.step);
            }
        }
    }

    // Fish shell completions
    {
        const wf = b.addWriteFiles();
        _ = wf.add("ghostty.fish", fish_completions.fish_completions);

        b.installDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/fish/vendor_completions.d",
        });
    }

    // Vim plugin
    {
        const wf = b.addWriteFiles();
        _ = wf.add("syntax/ghostty.vim", config_vim.syntax);
        _ = wf.add("ftdetect/ghostty.vim", config_vim.ftdetect);
        _ = wf.add("ftplugin/ghostty.vim", config_vim.ftplugin);
        b.installDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/vim/vimfiles",
        });
    }

    // Neovim plugin
    // This is just a copy-paste of the Vim plugin, but using a Neovim subdir.
    // By default, Neovim doesn't look inside share/vim/vimfiles. Some distros
    // configure it to do that however. Fedora, does not as a counterexample.
    {
        const wf = b.addWriteFiles();
        _ = wf.add("syntax/ghostty.vim", config_vim.syntax);
        _ = wf.add("ftdetect/ghostty.vim", config_vim.ftdetect);
        _ = wf.add("ftplugin/ghostty.vim", config_vim.ftplugin);
        b.installDirectory(.{
            .source_dir = wf.getDirectory(),
            .install_dir = .prefix,
            .install_subdir = "share/nvim/site",
        });
    }

    // Documentation
    if (emit_docs) {
        try buildDocumentation(b, config);
    } else {
        // We need to create the zig-out/share/man directory so that
        // macOS builds continue to work even if emit-docs doesn't
        // work.
        var wf = b.addWriteFiles();
        const path = "share/man/.placeholder";
        const placeholder = wf.add(path, "emit-docs not true so no man pages");
        b.getInstallStep().dependOn(&b.addInstallFile(placeholder, path).step);
    }

    // App (Linux)
    if (target.result.os.tag == .linux and config.app_runtime != .none) {
        // https://developer.gnome.org/documentation/guidelines/maintainer/integrating.html

        // Desktop file so that we have an icon and other metadata
        if (config.flatpak) {
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

    // libghostty (non-Darwin)
    if (!builtin.target.isDarwin() and config.app_runtime == .none) {
        // Shared
        {
            const lib = b.addSharedLibrary(.{
                .name = "ghostty",
                .root_source_file = b.path("src/main_c.zig"),
                .optimize = optimize,
                .target = target,
            });
            _ = try addDeps(b, lib, config);

            const lib_install = b.addInstallLibFile(
                lib.getEmittedBin(),
                "libghostty.so",
            );
            b.getInstallStep().dependOn(&lib_install.step);
        }

        // Static
        {
            const lib = b.addStaticLibrary(.{
                .name = "ghostty",
                .root_source_file = b.path("src/main_c.zig"),
                .optimize = optimize,
                .target = target,
            });
            _ = try addDeps(b, lib, config);

            const lib_install = b.addInstallLibFile(
                lib.getEmittedBin(),
                "libghostty.a",
            );
            b.getInstallStep().dependOn(&lib_install.step);
        }

        // Copy our ghostty.h to include.
        const header_install = b.addInstallHeaderFile(
            b.path("include/ghostty.h"),
            "ghostty.h",
        );
        b.getInstallStep().dependOn(&header_install.step);
    }

    // On Mac we can build the embedding library. This only handles the macOS lib.
    if (emit_xcframework) {
        // Create the universal macOS lib.
        const macos_lib_step, const macos_lib_path = try createMacOSLib(
            b,
            optimize,
            config,
        );

        // Add our library to zig-out
        const lib_install = b.addInstallLibFile(
            macos_lib_path,
            "libghostty-macos.a",
        );
        b.getInstallStep().dependOn(&lib_install.step);

        // Create the universal iOS lib.
        const ios_lib_step, const ios_lib_path = try createIOSLib(
            b,
            null,
            optimize,
            config,
        );

        // Add our library to zig-out
        const ios_lib_install = b.addInstallLibFile(
            ios_lib_path,
            "libghostty-ios.a",
        );
        b.getInstallStep().dependOn(&ios_lib_install.step);

        // Create the iOS simulator lib.
        const ios_sim_lib_step, const ios_sim_lib_path = try createIOSLib(
            b,
            .simulator,
            optimize,
            config,
        );

        // Add our library to zig-out
        const ios_sim_lib_install = b.addInstallLibFile(
            ios_sim_lib_path,
            "libghostty-ios-simulator.a",
        );
        b.getInstallStep().dependOn(&ios_sim_lib_install.step);

        // Copy our ghostty.h to include. The header file is shared by
        // all embedded targets.
        const header_install = b.addInstallHeaderFile(
            b.path("include/ghostty.h"),
            "ghostty.h",
        );
        b.getInstallStep().dependOn(&header_install.step);

        // The xcframework wraps our ghostty library so that we can link
        // it to the final app built with Swift.
        const xcframework = XCFrameworkStep.create(b, .{
            .name = "GhosttyKit",
            .out_path = "macos/GhosttyKit.xcframework",
            .libraries = &.{
                .{
                    .library = macos_lib_path,
                    .headers = b.path("include"),
                },
                .{
                    .library = ios_lib_path,
                    .headers = b.path("include"),
                },
                .{
                    .library = ios_sim_lib_path,
                    .headers = b.path("include"),
                },
            },
        });
        xcframework.step.dependOn(ios_lib_step);
        xcframework.step.dependOn(ios_sim_lib_step);
        xcframework.step.dependOn(macos_lib_step);
        xcframework.step.dependOn(&header_install.step);
        b.default_step.dependOn(xcframework.step);
    }

    // wasm
    {
        // Build our Wasm target.
        const wasm_crosstarget: std.Target.Query = .{
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

        // Modify our build configuration for wasm builds.
        const wasm_config: BuildConfig = config: {
            var copy = config;

            // Backends that are fixed for wasm
            copy.font_backend = .web_canvas;

            // Wasm-specific options
            copy.wasm_shared = wasm_shared;
            copy.wasm_target = wasm_target;

            break :config copy;
        };

        const wasm = b.addSharedLibrary(.{
            .name = "ghostty-wasm",
            .root_source_file = b.path("src/main_wasm.zig"),
            .target = b.resolveTargetQuery(wasm_crosstarget),
            .optimize = optimize,
        });

        // So that we can use web workers with our wasm binary
        wasm.import_memory = true;
        wasm.initial_memory = 65536 * 25;
        wasm.max_memory = 65536 * 65536; // Maximum number of pages in wasm32
        wasm.shared_memory = wasm_shared;

        // Stack protector adds extern requirements that we don't satisfy.
        wasm.root_module.stack_protector = false;

        // Wasm-specific deps
        _ = try addDeps(b, wasm, wasm_config);

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
            .root_source_file = b.path("src/main_wasm.zig"),
            .target = b.resolveTargetQuery(wasm_crosstarget),
        });

        _ = try addDeps(b, main_test, wasm_config);
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
        const test_filter = b.option([]const u8, "test-filter", "Filter for test");

        // Force all Mac builds to use a `generic` CPU. This avoids
        // potential issues with `highway` compile errors due to missing
        // `arm_neon` features (see for example https://github.com/mitchellh/ghostty/issues/1640).
        const test_target = if (target.result.os.tag == .macos and builtin.target.isDarwin())
            genericMacOSTarget(b, null)
        else
            target;

        const main_test = b.addTest(.{
            .name = "ghostty-test",
            .root_source_file = b.path("src/main.zig"),
            .target = test_target,
            .filter = test_filter,
        });

        {
            if (emit_test_exe) b.installArtifact(main_test);
            _ = try addDeps(b, main_test, config);
            const test_run = b.addRunArtifact(main_test);
            test_step.dependOn(&test_run.step);
        }
    }
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
    return switch (tag) {
        // We support back to the earliest officially supported version
        // of macOS by Apple. EOL versions are not supported.
        .macos => .{ .semver = .{
            .major = 13,
            .minor = 0,
            .patch = 0,
        } },

        // iOS 17 picked arbitrarily
        .ios => .{ .semver = .{
            .major = 17,
            .minor = 0,
            .patch = 0,
        } },

        // This should never happen currently. If we add a new target then
        // we should add a new case here.
        else => null,
    };
}

// Returns a ResolvedTarget for a mac with a `target.result.cpu.model.name` of `generic`.
// `b.standardTargetOptions()` returns a more specific cpu like `apple_a15`.
fn genericMacOSTarget(b: *std.Build, arch: ?std.Target.Cpu.Arch) ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
}

/// Creates a universal macOS libghostty library and returns the path
/// to the final library.
///
/// The library is always a fat static library currently because this is
/// expected to be used directly with Xcode and Swift. In the future, we
/// probably want to change this because it makes it harder to use the
/// library in other contexts.
fn createMacOSLib(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    config: BuildConfig,
) !struct { *std.Build.Step, std.Build.LazyPath } {
    const static_lib_aarch64 = lib: {
        const lib = b.addStaticLibrary(.{
            .name = "ghostty",
            .root_source_file = b.path("src/main_c.zig"),
            .target = genericMacOSTarget(b, .aarch64),
            .optimize = optimize,
        });
        lib.bundle_compiler_rt = true;
        lib.linkLibC();

        // Create a single static lib with all our dependencies merged
        var lib_list = try addDeps(b, lib, config);
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
            .root_source_file = b.path("src/main_c.zig"),
            .target = genericMacOSTarget(b, .x86_64),
            .optimize = optimize,
        });
        lib.bundle_compiler_rt = true;
        lib.linkLibC();

        // Create a single static lib with all our dependencies merged
        var lib_list = try addDeps(b, lib, config);
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

    return .{
        static_lib_universal.step,
        static_lib_universal.output,
    };
}

/// Create an Apple iOS/iPadOS build.
fn createIOSLib(
    b: *std.Build,
    abi: ?std.Target.Abi,
    optimize: std.builtin.OptimizeMode,
    config: BuildConfig,
) !struct { *std.Build.Step, std.Build.LazyPath } {
    const lib = b.addStaticLibrary(.{
        .name = "ghostty",
        .root_source_file = b.path("src/main_c.zig"),
        .optimize = optimize,
        .target = b.resolveTargetQuery(.{
            .cpu_arch = .aarch64,
            .os_tag = .ios,
            .os_version_min = osVersionMin(.ios),
            .abi = abi,
        }),
    });
    lib.bundle_compiler_rt = true;
    lib.linkLibC();

    // Create a single static lib with all our dependencies merged
    var lib_list = try addDeps(b, lib, config);
    try lib_list.append(lib.getEmittedBin());
    const libtool = LibtoolStep.create(b, .{
        .name = "ghostty",
        .out_name = "libghostty-ios-fat.a",
        .sources = lib_list.items,
    });
    libtool.step.dependOn(&lib.step);

    return .{
        libtool.step,
        libtool.output,
    };
}

/// Used to keep track of a list of file sources.
const LazyPathList = std.ArrayList(std.Build.LazyPath);

/// Adds and links all of the primary dependencies for the exe.
fn addDeps(
    b: *std.Build,
    step: *std.Build.Step.Compile,
    config: BuildConfig,
) !LazyPathList {
    // All object targets get access to a standard build_options module
    const exe_options = b.addOptions();
    try config.addOptions(exe_options);
    step.root_module.addOptions("build_options", exe_options);

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs = LazyPathList.init(b.allocator);
    errdefer static_libs.deinit();

    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    // For dynamic linking, we prefer dynamic linking and to search by
    // mode first. Mode first will search all paths for a dynamic library
    // before falling back to static.
    const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
        .preferred_link_mode = .dynamic,
        .search_strategy = .mode_first,
    };

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (config.font_backend.hasFreetype()) {
        const freetype_dep = b.dependency("freetype", .{
            .target = target,
            .optimize = optimize,
            .@"enable-libpng" = true,
        });
        step.root_module.addImport("freetype", freetype_dep.module("freetype"));

        if (b.systemIntegrationOption("freetype", .{})) {
            step.linkSystemLibrary2("bzip2", dynamic_link_opts);
            step.linkSystemLibrary2("freetype2", dynamic_link_opts);
        } else {
            step.linkLibrary(freetype_dep.artifact("freetype"));
            try static_libs.append(freetype_dep.artifact("freetype").getEmittedBin());
        }
    }

    // Harfbuzz
    _ = b.systemIntegrationOption("harfbuzz", .{}); // Shows it in help
    if (config.font_backend.hasHarfbuzz()) {
        const harfbuzz_dep = b.dependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = true,
            .@"enable-coretext" = config.font_backend.hasCoretext(),
        });

        step.root_module.addImport(
            "harfbuzz",
            harfbuzz_dep.module("harfbuzz"),
        );
        if (b.systemIntegrationOption("harfbuzz", .{})) {
            step.linkSystemLibrary2("harfbuzz", dynamic_link_opts);
        } else {
            step.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
            try static_libs.append(harfbuzz_dep.artifact("harfbuzz").getEmittedBin());
        }
    }

    // Fontconfig
    _ = b.systemIntegrationOption("fontconfig", .{}); // Shows it in help
    if (config.font_backend.hasFontconfig()) {
        const fontconfig_dep = b.dependency("fontconfig", .{
            .target = target,
            .optimize = optimize,
        });
        step.root_module.addImport(
            "fontconfig",
            fontconfig_dep.module("fontconfig"),
        );

        if (b.systemIntegrationOption("fontconfig", .{})) {
            step.linkSystemLibrary2("fontconfig", dynamic_link_opts);
        } else {
            step.linkLibrary(fontconfig_dep.artifact("fontconfig"));
            try static_libs.append(fontconfig_dep.artifact("fontconfig").getEmittedBin());
        }
    }

    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        const libpng_dep = b.dependency("libpng", .{
            .target = target,
            .optimize = optimize,
        });
        step.linkLibrary(libpng_dep.artifact("png"));
        try static_libs.append(libpng_dep.artifact("png").getEmittedBin());
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        const zlib_dep = b.dependency("zlib", .{
            .target = target,
            .optimize = optimize,
        });
        step.linkLibrary(zlib_dep.artifact("z"));
        try static_libs.append(zlib_dep.artifact("z").getEmittedBin());
    }

    // Oniguruma
    const oniguruma_dep = b.dependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    });
    step.root_module.addImport("oniguruma", oniguruma_dep.module("oniguruma"));
    if (b.systemIntegrationOption("oniguruma", .{})) {
        step.linkSystemLibrary2("oniguruma", dynamic_link_opts);
    } else {
        step.linkLibrary(oniguruma_dep.artifact("oniguruma"));
        try static_libs.append(oniguruma_dep.artifact("oniguruma").getEmittedBin());
    }

    // Glslang
    const glslang_dep = b.dependency("glslang", .{
        .target = target,
        .optimize = optimize,
    });
    step.root_module.addImport("glslang", glslang_dep.module("glslang"));
    if (b.systemIntegrationOption("glslang", .{})) {
        step.linkSystemLibrary2("glslang", dynamic_link_opts);
        step.linkSystemLibrary2("glslang-default-resource-limits", dynamic_link_opts);
    } else {
        step.linkLibrary(glslang_dep.artifact("glslang"));
        try static_libs.append(glslang_dep.artifact("glslang").getEmittedBin());
    }

    // Spirv-cross
    const spirv_cross_dep = b.dependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    });
    step.root_module.addImport("spirv_cross", spirv_cross_dep.module("spirv_cross"));
    if (b.systemIntegrationOption("spirv-cross", .{})) {
        step.linkSystemLibrary2("spirv-cross", dynamic_link_opts);
    } else {
        step.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
        try static_libs.append(spirv_cross_dep.artifact("spirv_cross").getEmittedBin());
    }

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        step.linkSystemLibrary2("simdutf", dynamic_link_opts);
    } else {
        const simdutf_dep = b.dependency("simdutf", .{
            .target = target,
            .optimize = optimize,
        });
        step.linkLibrary(simdutf_dep.artifact("simdutf"));
        try static_libs.append(simdutf_dep.artifact("simdutf").getEmittedBin());
    }

    // Sentry
    const sentry_dep = b.dependency("sentry", .{
        .target = target,
        .optimize = optimize,
        .backend = .breakpad,
    });
    step.root_module.addImport("sentry", sentry_dep.module("sentry"));
    if (target.result.os.tag != .windows) {
        // Sentry
        step.linkLibrary(sentry_dep.artifact("sentry"));
        try static_libs.append(sentry_dep.artifact("sentry").getEmittedBin());

        // We also need to include breakpad in the static libs.
        const breakpad_dep = sentry_dep.builder.dependency("breakpad", .{
            .target = target,
            .optimize = optimize,
        });
        try static_libs.append(breakpad_dep.artifact("breakpad").getEmittedBin());
    }

    // Wasm we do manually since it is such a different build.
    if (step.rootModuleTarget().cpu.arch == .wasm32) {
        const js_dep = b.dependency("zig_js", .{
            .target = target,
            .optimize = optimize,
        });
        step.root_module.addImport("zig-js", js_dep.module("zig-js"));

        return static_libs;
    }

    // On Linux, we need to add a couple common library paths that aren't
    // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
    // on x86_64.
    if (step.rootModuleTarget().os.tag == .linux) {
        const triple = try step.rootModuleTarget().linuxTriple(b.allocator);
        step.addLibraryPath(.{ .cwd_relative = b.fmt("/usr/lib/{s}", .{triple}) });
    }

    // C files
    step.linkLibC();
    step.addIncludePath(b.path("src/stb"));
    step.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });
    if (step.rootModuleTarget().os.tag == .linux) {
        step.addIncludePath(b.path("src/apprt/gtk"));
    }

    // C++ files
    step.linkLibCpp();
    step.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;

        step.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = if (step.rootModuleTarget().cpu.arch == .x86_64) &.{
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{},
        });
    }

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    if (step.rootModuleTarget().isDarwin()) {
        try @import("apple_sdk").addPaths(b, &step.root_module);
        try addMetallib(b, step);
    }

    // Other dependencies, mostly pure Zig
    step.root_module.addImport("opengl", b.dependency(
        "opengl",
        .{},
    ).module("opengl"));
    step.root_module.addImport("vaxis", b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .libxev = false,
        .images = false,
    }).module("vaxis"));
    step.root_module.addImport("wuffs", b.dependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    }).module("wuffs"));
    step.root_module.addImport("xev", b.dependency("libxev", .{
        .target = target,
        .optimize = optimize,
    }).module("xev"));
    step.root_module.addImport("z2d", b.addModule("z2d", .{
        .root_source_file = b.dependency("z2d", .{}).path("src/z2d.zig"),
        .target = target,
        .optimize = optimize,
    }));
    step.root_module.addImport("ziglyph", b.dependency("ziglyph", .{
        .target = target,
        .optimize = optimize,
    }).module("ziglyph"));
    step.root_module.addImport("zf", b.dependency("zf", .{
        .target = target,
        .optimize = optimize,
    }).module("zf"));

    // Mac Stuff
    if (step.rootModuleTarget().isDarwin()) {
        const objc_dep = b.dependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        });
        const macos_dep = b.dependency("macos", .{
            .target = target,
            .optimize = optimize,
        });

        step.root_module.addImport("objc", objc_dep.module("objc"));
        step.root_module.addImport("macos", macos_dep.module("macos"));
        step.linkLibrary(macos_dep.artifact("macos"));
        try static_libs.append(macos_dep.artifact("macos").getEmittedBin());

        if (config.renderer == .opengl) {
            step.linkFramework("OpenGL");
        }
    }

    // cimgui
    const cimgui_dep = b.dependency("cimgui", .{
        .target = target,
        .optimize = optimize,
    });
    step.root_module.addImport("cimgui", cimgui_dep.module("cimgui"));
    step.linkLibrary(cimgui_dep.artifact("cimgui"));
    try static_libs.append(cimgui_dep.artifact("cimgui").getEmittedBin());

    // Highway
    const highway_dep = b.dependency("highway", .{
        .target = target,
        .optimize = optimize,
    });
    step.linkLibrary(highway_dep.artifact("highway"));
    try static_libs.append(highway_dep.artifact("highway").getEmittedBin());

    // utfcpp - This is used as a dependency on our hand-written C++ code
    const utfcpp_dep = b.dependency("utfcpp", .{
        .target = target,
        .optimize = optimize,
    });
    step.linkLibrary(utfcpp_dep.artifact("utfcpp"));
    try static_libs.append(utfcpp_dep.artifact("utfcpp").getEmittedBin());

    // If we're building an exe then we have additional dependencies.
    if (step.kind != .lib) {
        // We always statically compile glad
        step.addIncludePath(b.path("vendor/glad/include/"));
        step.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });

        // When we're targeting flatpak we ALWAYS link GTK so we
        // get access to glib for dbus.
        if (config.flatpak) step.linkSystemLibrary2("gtk4", dynamic_link_opts);

        switch (config.app_runtime) {
            .none => {},

            .glfw => glfw: {
                const mach_glfw_dep = b.lazyDependency("mach_glfw", .{
                    .target = target,
                    .optimize = optimize,
                }) orelse break :glfw;
                step.root_module.addImport("glfw", mach_glfw_dep.module("mach-glfw"));
            },

            .gtk => {
                step.linkSystemLibrary2("gtk4", dynamic_link_opts);
                if (config.libadwaita) step.linkSystemLibrary2("adwaita-1", dynamic_link_opts);

                {
                    const gresource = @import("src/apprt/gtk/gresource.zig");

                    const wf = b.addWriteFiles();
                    const gresource_xml = wf.add("gresource.xml", gresource.gresource_xml);

                    const generate_resources_c = b.addSystemCommand(&.{
                        "glib-compile-resources",
                        "--c-name",
                        "ghostty",
                        "--generate-source",
                        "--target",
                    });
                    const ghostty_resources_c = generate_resources_c.addOutputFileArg("ghostty_resources.c");
                    generate_resources_c.addFileArg(gresource_xml);
                    generate_resources_c.extra_file_dependencies = &gresource.dependencies;
                    step.addCSourceFile(.{ .file = ghostty_resources_c, .flags = &.{} });

                    const generate_resources_h = b.addSystemCommand(&.{
                        "glib-compile-resources",
                        "--c-name",
                        "ghostty",
                        "--generate-header",
                        "--target",
                    });
                    const ghostty_resources_h = generate_resources_h.addOutputFileArg("ghostty_resources.h");
                    generate_resources_h.addFileArg(gresource_xml);
                    generate_resources_h.extra_file_dependencies = &gresource.dependencies;
                    step.addIncludePath(ghostty_resources_h.dirname());
                }
            },
        }
    }

    try addHelp(b, step, config);
    try addUnicodeTables(b, step);

    return static_libs;
}

/// Generate Metal shader library
fn addMetallib(
    b: *std.Build,
    step: *std.Build.Step.Compile,
) !void {
    const metal_step = MetallibStep.create(b, .{
        .name = "Ghostty",
        .target = step.root_module.resolved_target.?,
        .sources = &.{b.path("src/renderer/shaders/cell.metal")},
    });

    metal_step.output.addStepDependencies(&step.step);
    step.root_module.addAnonymousImport("ghostty_metallib", .{
        .root_source_file = metal_step.output,
    });
}

/// Generate help files
fn addHelp(
    b: *std.Build,
    step_: ?*std.Build.Step.Compile,
    config: BuildConfig,
) !void {
    // Our static state between runs. We memoize our help strings
    // so that we only execute the help generation once.
    const HelpState = struct {
        var generated: ?std.Build.LazyPath = null;
    };

    const help_output = HelpState.generated orelse strings: {
        const help_exe = b.addExecutable(.{
            .name = "helpgen",
            .root_source_file = b.path("src/helpgen.zig"),
            .target = b.host,
        });
        if (step_ == null) b.installArtifact(help_exe);

        const help_config = config: {
            var copy = config;
            copy.exe_entrypoint = .helpgen;
            break :config copy;
        };
        const options = b.addOptions();
        try help_config.addOptions(options);
        help_exe.root_module.addOptions("build_options", options);

        const help_run = b.addRunArtifact(help_exe);
        HelpState.generated = help_run.captureStdOut();
        break :strings HelpState.generated.?;
    };

    if (step_) |step| {
        help_output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("help_strings", .{
            .root_source_file = help_output,
        });
    }
}

/// Generate unicode fast lookup tables
fn addUnicodeTables(
    b: *std.Build,
    step_: ?*std.Build.Step.Compile,
) !void {
    // Our static state between runs. We memoize our output to gen once
    const State = struct {
        var generated: ?std.Build.LazyPath = null;
    };

    const output = State.generated orelse strings: {
        const exe = b.addExecutable(.{
            .name = "unigen",
            .root_source_file = b.path("src/unicode/props.zig"),
            .target = b.host,
        });
        exe.linkLibC();
        if (step_ == null) b.installArtifact(exe);

        const ziglyph_dep = b.dependency("ziglyph", .{
            .target = b.host,
        });
        exe.root_module.addImport("ziglyph", ziglyph_dep.module("ziglyph"));

        const help_run = b.addRunArtifact(exe);
        State.generated = help_run.captureStdOut();
        break :strings State.generated.?;
    };

    if (step_) |step| {
        output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("unicode_tables", .{
            .root_source_file = output,
        });
    }
}

/// Generate documentation (manpages, etc.) from help strings
fn buildDocumentation(
    b: *std.Build,
    config: BuildConfig,
) !void {
    const manpages = [_]struct {
        name: []const u8,
        section: []const u8,
    }{
        .{ .name = "ghostty", .section = "1" },
        .{ .name = "ghostty", .section = "5" },
    };

    inline for (manpages) |manpage| {
        const generate_markdown = b.addExecutable(.{
            .name = "mdgen_" ++ manpage.name ++ "_" ++ manpage.section,
            .root_source_file = b.path("src/main.zig"),
            .target = b.host,
        });
        try addHelp(b, generate_markdown, config);

        const gen_config = config: {
            var copy = config;
            copy.exe_entrypoint = @field(
                build_config.ExeEntrypoint,
                "mdgen_" ++ manpage.name ++ "_" ++ manpage.section,
            );
            break :config copy;
        };

        const generate_markdown_options = b.addOptions();
        try gen_config.addOptions(generate_markdown_options);
        generate_markdown.root_module.addOptions("build_options", generate_markdown_options);

        const generate_markdown_step = b.addRunArtifact(generate_markdown);
        const markdown_output = generate_markdown_step.captureStdOut();

        b.getInstallStep().dependOn(&b.addInstallFile(
            markdown_output,
            "share/ghostty/doc/" ++ manpage.name ++ "." ++ manpage.section ++ ".md",
        ).step);

        const generate_html = b.addSystemCommand(&.{"pandoc"});
        generate_html.addArgs(&.{
            "--standalone",
            "--from",
            "markdown",
            "--to",
            "html",
        });
        generate_html.addFileArg(markdown_output);

        b.getInstallStep().dependOn(&b.addInstallFile(
            generate_html.captureStdOut(),
            "share/ghostty/doc/" ++ manpage.name ++ "." ++ manpage.section ++ ".html",
        ).step);

        const generate_manpage = b.addSystemCommand(&.{"pandoc"});
        generate_manpage.addArgs(&.{
            "--standalone",
            "--from",
            "markdown",
            "--to",
            "man",
        });
        generate_manpage.addFileArg(markdown_output);

        b.getInstallStep().dependOn(&b.addInstallFile(
            generate_manpage.captureStdOut(),
            "share/man/man" ++ manpage.section ++ "/" ++ manpage.name ++ "." ++ manpage.section,
        ).step);
    }
}

fn benchSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    config: BuildConfig,
    install: bool,
) !void {
    // Open the directory ./src/bench
    const c_dir_path = (comptime root()) ++ "/src/bench";
    var c_dir = try fs.cwd().openDir(c_dir_path, .{ .iterate = true });
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

        // Executable builder.
        const bin_name = try std.fmt.allocPrint(b.allocator, "bench-{s}", .{name});
        const c_exe = b.addExecutable(.{
            .name = bin_name,
            .root_source_file = b.path("src/main.zig"),
            .target = target,

            // We always want our benchmarks to be in release mode.
            .optimize = .ReleaseFast,
        });
        c_exe.linkLibC();
        if (install) b.installArtifact(c_exe);
        _ = try addDeps(b, c_exe, config: {
            var copy = config;
            var enum_name: [64]u8 = undefined;
            @memcpy(enum_name[0..name.len], name);
            std.mem.replaceScalar(u8, enum_name[0..name.len], '-', '_');

            var buf: [64]u8 = undefined;
            copy.exe_entrypoint = std.meta.stringToEnum(
                build_config.ExeEntrypoint,
                try std.fmt.bufPrint(&buf, "bench_{s}", .{enum_name[0..name.len]}),
            ).?;

            break :config copy;
        });
    }
}

fn conformanceSteps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Mode,
) !std.StringHashMap(*CompileStep) {
    var map = std.StringHashMap(*CompileStep).init(b.allocator);

    // Open the directory ./conformance
    const c_dir_path = (comptime root()) ++ "/conformance";
    var c_dir = try fs.cwd().openDir(c_dir_path, .{ .iterate = true });
    defer c_dir.close();

    // Go through and add each as a step
    var c_dir_it = c_dir.iterate();
    while (try c_dir_it.next()) |entry| {
        // Get the index of the last '.' so we can strip the extension.
        const index = std.mem.lastIndexOfScalar(u8, entry.name, '.') orelse continue;
        if (index == 0) continue;

        // Name of the conformance app and full path to the entrypoint.
        const name = try b.allocator.dupe(u8, entry.name[0..index]);
        const path = try fs.path.join(b.allocator, &[_][]const u8{
            c_dir_path,
            entry.name,
        });

        // Executable builder.
        const c_exe = b.addExecutable(.{
            .name = name,
            .root_source_file = b.path(path),
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
const color_map = std.StaticStringMap([]const u8).initComptime(.{
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
