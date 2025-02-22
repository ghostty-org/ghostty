const SharedDeps = @This();

const std = @import("std");
const Scanner = @import("zig_wayland").Scanner;
const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try HelpStrings.init(b, cfg),
        .unicode_tables = try UnicodeTables.init(b),
        .framedata = try GhosttyFrameData.init(b),

        // Setup by retarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    return result;
}

/// Retarget our dependencies for another build target. Modifies in-place.
pub fn retarget(
    self: *const SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !SharedDeps {
    var result = self.*;
    try result.initTarget(b, target);
    return result;
}

/// Change the exe entrypoint.
pub fn changeEntrypoint(
    self: *const SharedDeps,
    b: *std.Build,
    entrypoint: Config.ExeEntrypoint,
) !SharedDeps {
    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.exe_entrypoint = entrypoint;

    var result = self.*;
    result.config = config;
    return result;
}

fn initTarget(
    self: *SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = MetallibStep.create(b, .{
        .name = "Ghostty",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/cell.metal")},
    });

    // Change our config
    const config = try b.allocator.create(Config);
    config.* = self.config.*;
    config.target = target;
    self.config = config;

    // Setup our shared build options
    self.options = b.addOptions();
    try self.config.addOptions(self.options);
}

pub fn add(
    self: *const SharedDeps,
    step: *std.Build.Step.Compile,
) !LazyPathList {
    const b = step.step.owner;

    // We could use our config.target/optimize fields here but its more
    // correct to always match our step.
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    // We maintain a list of our static libraries and return it so that
    // we can build a single fat static library for the final app.
    var static_libs = LazyPathList.init(b.allocator);
    errdefer static_libs.deinit();

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Freetype
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (self.config.font_backend.hasFreetype()) {
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
    if (self.config.font_backend.hasHarfbuzz()) {
        const harfbuzz_dep = b.dependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = true,
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
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
    if (self.config.font_backend.hasFontconfig()) {
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
    if (self.config.sentry) {
        const sentry_dep = b.dependency("sentry", .{
            .target = target,
            .optimize = optimize,
            .backend = .breakpad,
        });

        step.root_module.addImport("sentry", sentry_dep.module("sentry"));

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

        const metallib = self.metallib.?;
        metallib.output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("ghostty_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    step.root_module.addImport("opengl", b.dependency(
        "opengl",
        .{},
    ).module("opengl"));
    step.root_module.addImport("vaxis", b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
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
        .with_tui = false,
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

        if (self.config.renderer == .opengl) {
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
        if (self.config.flatpak) step.linkSystemLibrary2("gtk4", dynamic_link_opts);

        switch (self.config.app_runtime) {
            .none => {},

            .glfw => glfw: {
                const mach_glfw_dep = b.lazyDependency("mach_glfw", .{
                    .target = target,
                    .optimize = optimize,
                }) orelse break :glfw;
                step.root_module.addImport("glfw", mach_glfw_dep.module("mach-glfw"));
            },

            .gtk => {
                const gobject = b.dependency("gobject", .{
                    .target = target,
                    .optimize = optimize,
                });
                const gobject_imports = .{
                    .{ "gobject", "gobject2" },
                    .{ "gio", "gio2" },
                    .{ "glib", "glib2" },
                    .{ "gtk", "gtk4" },
                    .{ "gdk", "gdk4" },
                };
                inline for (gobject_imports) |import| {
                    const name, const module = import;
                    step.root_module.addImport(name, gobject.module(module));
                }

                step.linkSystemLibrary2("gtk4", dynamic_link_opts);
                step.linkSystemLibrary2("libadwaita-1", dynamic_link_opts);
                step.root_module.addImport("adw", gobject.module("adw1"));

                if (self.config.x11) {
                    step.linkSystemLibrary2("X11", dynamic_link_opts);
                    step.root_module.addImport("gdk_x11", gobject.module("gdkx114"));
                }

                if (self.config.wayland) {
                    const scanner = Scanner.create(b.dependency("zig_wayland", .{}), .{
                        // We shouldn't be using getPath but we need to for now
                        // https://codeberg.org/ifreund/zig-wayland/issues/66
                        .wayland_xml = b.dependency("wayland", .{})
                            .path("protocol/wayland.xml"),
                        .wayland_protocols = b.dependency("wayland_protocols", .{})
                            .path(""),
                    });

                    const wayland = b.createModule(.{ .root_source_file = scanner.result });

                    const plasma_wayland_protocols = b.dependency("plasma_wayland_protocols", .{
                        .target = target,
                        .optimize = optimize,
                    });

                    // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398
                    scanner.addCustomProtocol(plasma_wayland_protocols.path("src/protocols/blur.xml"));
                    scanner.addCustomProtocol(plasma_wayland_protocols.path("src/protocols/server-decoration.xml"));

                    scanner.generate("wl_compositor", 1);
                    scanner.generate("org_kde_kwin_blur_manager", 1);
                    scanner.generate("org_kde_kwin_server_decoration_manager", 1);

                    step.root_module.addImport("wayland", wayland);
                    step.root_module.addImport("gdk_wayland", gobject.module("gdkwayland4"));
                    step.linkSystemLibrary2("wayland-client", dynamic_link_opts);
                }

                {
                    const gresource = @import("../apprt/gtk/gresource.zig");

                    const gresource_xml = gresource_xml: {
                        const generate_gresource_xml = b.addExecutable(.{
                            .name = "generate_gresource_xml",
                            .root_source_file = b.path("src/apprt/gtk/gresource.zig"),
                            .target = b.host,
                        });

                        const generate = b.addRunArtifact(generate_gresource_xml);

                        for (gresource.blueprint_files) |blueprint_file| {
                            const blueprint_compiler = b.addSystemCommand(&.{
                                "blueprint-compiler",
                                "compile",
                                "--output",
                            });
                            const ui_file = blueprint_compiler.addOutputFileArg(b.fmt("{s}.ui", .{blueprint_file}));
                            blueprint_compiler.addFileArg(b.path(b.fmt("src/apprt/gtk/ui/{s}.blp", .{blueprint_file})));
                            generate.addFileArg(ui_file);
                        }

                        break :gresource_xml generate.captureStdOut();
                    };

                    {
                        const gtk_builder_check = b.addExecutable(.{
                            .name = "gtk_builder_check",
                            .root_source_file = b.path("src/apprt/gtk/builder_check.zig"),
                            .target = b.host,
                        });
                        gtk_builder_check.root_module.addOptions("build_options", self.options);
                        gtk_builder_check.root_module.addImport("gtk", gobject.module("gtk4"));
                        gtk_builder_check.root_module.addImport("adw", gobject.module("adw1"));

                        for (gresource.dependencies) |pathname| {
                            const extension = std.fs.path.extension(pathname);
                            if (!std.mem.eql(u8, extension, ".ui")) continue;
                            const check = b.addRunArtifact(gtk_builder_check);
                            check.addFileArg(b.path(pathname));
                            step.step.dependOn(&check.step);
                        }
                    }

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

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);
    self.framedata.addImport(step);

    return static_libs;
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
