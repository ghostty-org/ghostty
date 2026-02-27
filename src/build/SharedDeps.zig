const SharedDeps = @This();

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");
const DistResource = @import("GhosttyDist.zig").Resource;

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,
uucode_tables: std.Build.LazyPath,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    const uucode_tables = blk: {
        const uucode = b.dependency("uucode", .{
            .build_config_path = b.path("src/build/uucode_config.zig"),
        });

        break :blk uucode.namedLazyPath("tables.zig");
    };

    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b, uucode_tables),
        .framedata = try .init(b),
        .uucode_tables = uucode_tables,

        // Setup by retarget
        .options = undefined,
        .metallib = undefined,
    };
    try result.initTarget(b, cfg.target);
    if (cfg.emit_unicode_table_gen) result.unicode_tables.install(b);
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
    result.options = b.addOptions();
    try config.addOptions(result.options);

    return result;
}

fn initTarget(
    self: *SharedDeps,
    b: *std.Build,
    target: std.Build.ResolvedTarget,
) !void {
    // Update our metallib
    self.metallib = .create(b, .{
        .name = "Ghostty",
        .target = target,
        .sources = &.{b.path("src/renderer/shaders/shaders.metal")},
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
    var static_libs: LazyPathList = .empty;
    errdefer static_libs.deinit(b.allocator);

    // WARNING: This is a hack!
    // If we're cross-compiling to Darwin then we don't add any deps.
    // We don't support cross-compiling to Darwin but due to the way
    // lazy dependencies work with Zig, we call this function. So we just
    // bail. The build will fail but the build would've failed anyways.
    // And this lets other non-platform-specific targets like `lib-vt`
    // cross-compile properly.
    if (!builtin.target.os.tag.isDarwin() and
        self.config.target.result.os.tag.isDarwin())
    {
        return static_libs;
    }

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Every exe needs the terminal options
    self.config.terminalOptions().add(b, step.root_module);

    // Freetype. We always include this even if our font backend doesn't
    // use it because Dear Imgui uses Freetype.
    _ = b.systemIntegrationOption("freetype", .{}); // Shows it in help
    if (b.lazyDependency("freetype", .{
        .target = target,
        .optimize = optimize,
        .@"enable-libpng" = true,
    })) |freetype_dep| {
        step.root_module.addImport(
            "freetype",
            freetype_dep.module("freetype"),
        );

        if (b.systemIntegrationOption("freetype", .{})) {
            step.linkSystemLibrary2("bzip2", dynamic_link_opts);
            step.linkSystemLibrary2("freetype2", dynamic_link_opts);
        } else {
            step.linkLibrary(freetype_dep.artifact("freetype"));
            try static_libs.append(
                b.allocator,
                freetype_dep.artifact("freetype").getEmittedBin(),
            );
        }
    }

    // Harfbuzz
    _ = b.systemIntegrationOption("harfbuzz", .{}); // Shows it in help
    if (self.config.font_backend.hasHarfbuzz()) {
        if (b.lazyDependency("harfbuzz", .{
            .target = target,
            .optimize = optimize,
            .@"enable-freetype" = self.config.font_backend.hasFreetype(),
            .@"enable-coretext" = self.config.font_backend.hasCoretext(),
        })) |harfbuzz_dep| {
            step.root_module.addImport(
                "harfbuzz",
                harfbuzz_dep.module("harfbuzz"),
            );
            if (b.systemIntegrationOption("harfbuzz", .{})) {
                step.linkSystemLibrary2("harfbuzz", dynamic_link_opts);
            } else {
                step.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
                try static_libs.append(
                    b.allocator,
                    harfbuzz_dep.artifact("harfbuzz").getEmittedBin(),
                );
            }
        }
    }

    // Fontconfig
    _ = b.systemIntegrationOption("fontconfig", .{}); // Shows it in help
    if (self.config.font_backend.hasFontconfig()) {
        if (b.lazyDependency("fontconfig", .{
            .target = target,
            .optimize = optimize,
        })) |fontconfig_dep| {
            step.root_module.addImport(
                "fontconfig",
                fontconfig_dep.module("fontconfig"),
            );

            if (b.systemIntegrationOption("fontconfig", .{})) {
                step.linkSystemLibrary2("fontconfig", dynamic_link_opts);
            } else {
                step.linkLibrary(fontconfig_dep.artifact("fontconfig"));
                try static_libs.append(
                    b.allocator,
                    fontconfig_dep.artifact("fontconfig").getEmittedBin(),
                );
            }
        }
    }

    // Libpng - Ghostty doesn't actually use this directly, its only used
    // through dependencies, so we only need to add it to our static
    // libs list if we're not using system integration. The dependencies
    // will handle linking it.
    if (!b.systemIntegrationOption("libpng", .{})) {
        if (b.lazyDependency("libpng", .{
            .target = target,
            .optimize = optimize,
        })) |libpng_dep| {
            step.linkLibrary(libpng_dep.artifact("png"));
            try static_libs.append(
                b.allocator,
                libpng_dep.artifact("png").getEmittedBin(),
            );
        }
    }

    // Zlib - same as libpng, only used through dependencies.
    if (!b.systemIntegrationOption("zlib", .{})) {
        if (b.lazyDependency("zlib", .{
            .target = target,
            .optimize = optimize,
        })) |zlib_dep| {
            step.linkLibrary(zlib_dep.artifact("z"));
            try static_libs.append(
                b.allocator,
                zlib_dep.artifact("z").getEmittedBin(),
            );
        }
    }

    // Oniguruma
    if (b.lazyDependency("oniguruma", .{
        .target = target,
        .optimize = optimize,
    })) |oniguruma_dep| {
        step.root_module.addImport(
            "oniguruma",
            oniguruma_dep.module("oniguruma"),
        );
        if (b.systemIntegrationOption("oniguruma", .{})) {
            step.linkSystemLibrary2("oniguruma", dynamic_link_opts);
        } else {
            step.linkLibrary(oniguruma_dep.artifact("oniguruma"));
            try static_libs.append(
                b.allocator,
                oniguruma_dep.artifact("oniguruma").getEmittedBin(),
            );
        }
    }

    // Glslang
    if (b.lazyDependency("glslang", .{
        .target = target,
        .optimize = optimize,
    })) |glslang_dep| {
        step.root_module.addImport("glslang", glslang_dep.module("glslang"));
        if (b.systemIntegrationOption("glslang", .{})) {
            step.linkSystemLibrary2("glslang", dynamic_link_opts);
            step.linkSystemLibrary2(
                "glslang-default-resource-limits",
                dynamic_link_opts,
            );
        } else {
            step.linkLibrary(glslang_dep.artifact("glslang"));
            try static_libs.append(
                b.allocator,
                glslang_dep.artifact("glslang").getEmittedBin(),
            );
        }
    }

    // Spirv-cross
    if (b.lazyDependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
    })) |spirv_cross_dep| {
        step.root_module.addImport(
            "spirv_cross",
            spirv_cross_dep.module("spirv_cross"),
        );
        if (b.systemIntegrationOption("spirv-cross", .{})) {
            step.linkSystemLibrary2("spirv-cross-c-shared", dynamic_link_opts);
        } else {
            step.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
            try static_libs.append(
                b.allocator,
                spirv_cross_dep.artifact("spirv_cross").getEmittedBin(),
            );
        }
    }

    // Sentry
    if (self.config.sentry) {
        if (b.lazyDependency("sentry", .{
            .target = target,
            .optimize = optimize,
            .backend = .breakpad,
        })) |sentry_dep| {
            step.root_module.addImport(
                "sentry",
                sentry_dep.module("sentry"),
            );
            step.linkLibrary(sentry_dep.artifact("sentry"));
            try static_libs.append(
                b.allocator,
                sentry_dep.artifact("sentry").getEmittedBin(),
            );

            // We also need to include breakpad in the static libs.
            if (sentry_dep.builder.lazyDependency("breakpad", .{
                .target = target,
                .optimize = optimize,
            })) |breakpad_dep| {
                try static_libs.append(
                    b.allocator,
                    breakpad_dep.artifact("breakpad").getEmittedBin(),
                );
            }
        }
    }

    // Simd
    if (self.config.simd) try addSimd(
        b,
        step.root_module,
        &static_libs,
    );

    // Wasm we do manually since it is such a different build.
    if (step.rootModuleTarget().cpu.arch == .wasm32) {
        if (b.lazyDependency("zig_js", .{
            .target = target,
            .optimize = optimize,
        })) |js_dep| {
            step.root_module.addImport(
                "zig-js",
                js_dep.module("zig-js"),
            );
        }

        return static_libs;
    }

    // On Linux, we need to add a couple common library paths that aren't
    // on the standard search list. i.e. GTK is often in /usr/lib/x86_64-linux-gnu
    // on x86_64.
    if (step.rootModuleTarget().os.tag == .linux) {
        const triple = try step.rootModuleTarget().linuxTriple(b.allocator);
        const path = b.fmt("/usr/lib/{s}", .{triple});
        if (std.fs.accessAbsolute(path, .{})) {
            step.addLibraryPath(.{ .cwd_relative = path });
        } else |_| {}
    }

    // C files
    step.linkLibC();
    step.addIncludePath(b.path("src/stb"));
    step.addCSourceFiles(.{ .files = &.{"src/stb/stb.c"} });
    if (step.rootModuleTarget().os.tag == .linux) {
        step.addIncludePath(b.path("src/apprt/gtk"));
    }

    // libcpp is required for various dependencies
    step.linkLibCpp();

    // We always require the system SDK so that our system headers are available.
    // This makes things like `os/log.h` available for cross-compiling.
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        try @import("apple_sdk").addPaths(b, step);

        const metallib = self.metallib.?;
        metallib.output.addStepDependencies(&step.step);
        step.root_module.addAnonymousImport("ghostty_metallib", .{
            .root_source_file = metallib.output,
        });
    }

    // Other dependencies, mostly pure Zig
    if (b.lazyDependency("opengl", .{})) |dep| {
        step.root_module.addImport("opengl", dep.module("opengl"));
    }
    if (b.lazyDependency("vaxis", .{})) |dep| {
        step.root_module.addImport("vaxis", dep.module("vaxis"));
    }
    if (b.lazyDependency("wuffs", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("wuffs", dep.module("wuffs"));
    }
    if (b.lazyDependency("libxev", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("xev", dep.module("xev"));
    }
    if (b.lazyDependency("z2d", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        step.root_module.addImport("z2d", dep.module("z2d"));
    }
    self.addUucode(b, step.root_module, target, optimize);
    if (b.lazyDependency("zf", .{
        .target = target,
        .optimize = optimize,
        .with_tui = false,
    })) |dep| {
        step.root_module.addImport("zf", dep.module("zf"));
    }

    // Mac Stuff
    if (step.rootModuleTarget().os.tag.isDarwin()) {
        if (b.lazyDependency("zig_objc", .{
            .target = target,
            .optimize = optimize,
        })) |objc_dep| {
            step.root_module.addImport(
                "objc",
                objc_dep.module("objc"),
            );
        }

        if (b.lazyDependency("macos", .{
            .target = target,
            .optimize = optimize,
        })) |macos_dep| {
            step.root_module.addImport(
                "macos",
                macos_dep.module("macos"),
            );
            step.linkLibrary(
                macos_dep.artifact("macos"),
            );
            try static_libs.append(
                b.allocator,
                macos_dep.artifact("macos").getEmittedBin(),
            );
        }

        if (self.config.renderer == .opengl) {
            step.linkFramework("OpenGL");
        }

        // Apple platforms do not include libc libintl so we bundle it.
        // This is LGPL but since our source code is open source we are
        // in compliance with the LGPL since end users can modify this
        // build script to replace the bundled libintl with their own.
        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.linkLibrary(libintl_dep.artifact("intl"));
            try static_libs.append(
                b.allocator,
                libintl_dep.artifact("intl").getEmittedBin(),
            );
        }
    }

    // cimgui
    if (b.lazyDependency("dcimgui", .{
        .target = target,
        .optimize = optimize,
        .freetype = true,
        .@"backend-metal" = target.result.os.tag.isDarwin(),
        .@"backend-osx" = target.result.os.tag == .macos,
        // OpenGL3 backend should only be built on non-Apple targets.
        // Apple platforms use Metal (and macOS may also use the OSX backend).
        .@"backend-opengl3" = !target.result.os.tag.isDarwin(),
    })) |dep| {
        step.root_module.addImport("dcimgui", dep.module("dcimgui"));
        step.linkLibrary(dep.artifact("dcimgui"));
        try static_libs.append(
            b.allocator,
            dep.artifact("dcimgui").getEmittedBin(),
        );
    }

    // Fonts
    {
        // JetBrains Mono
        if (b.lazyDependency("jetbrains_mono", .{})) |jb_mono| {
            step.root_module.addAnonymousImport(
                "jetbrains_mono_regular",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Regular.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Bold.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-Italic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_bold_italic",
                .{ .root_source_file = jb_mono.path("fonts/ttf/JetBrainsMono-BoldItalic.ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono[wght].ttf") },
            );
            step.root_module.addAnonymousImport(
                "jetbrains_mono_variable_italic",
                .{ .root_source_file = jb_mono.path("fonts/variable/JetBrainsMono-Italic[wght].ttf") },
            );
        }

        // Symbols-only nerd font
        if (b.lazyDependency("nerd_fonts_symbols_only", .{})) |nf_symbols| {
            step.root_module.addAnonymousImport(
                "nerd_fonts_symbols_only",
                .{ .root_source_file = nf_symbols.path("SymbolsNerdFont-Regular.ttf") },
            );
        }
    }

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
            .gtk => try self.addGtkNg(step),
        }
    }

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);
    self.framedata.addImport(step);

    return static_libs;
}

/// Setup the dependencies for the GTK apprt build.
fn addGtkNg(
    self: *const SharedDeps,
    step: *std.Build.Step.Compile,
) !void {
    const b = step.step.owner;
    const target = step.root_module.resolved_target.?;
    const optimize = step.root_module.optimize.?;

    const gobject_ = b.lazyDependency("gobject", .{
        .target = target,
        .optimize = optimize,
    });
    if (gobject_) |gobject| {
        const gobject_imports = .{
            .{ "adw", "adw1" },
            .{ "gdk", "gdk4" },
            .{ "gio", "gio2" },
            .{ "glib", "glib2" },
            .{ "gobject", "gobject2" },
            .{ "gtk", "gtk4" },
            .{ "xlib", "xlib2" },
        };
        inline for (gobject_imports) |import| {
            const name, const module = import;
            step.root_module.addImport(name, gobject.module(module));
        }
    }

    step.linkSystemLibrary2("gtk4", dynamic_link_opts);
    step.linkSystemLibrary2("libadwaita-1", dynamic_link_opts);

    if (self.config.x11) {
        step.linkSystemLibrary2("X11", dynamic_link_opts);
        if (gobject_) |gobject| {
            step.root_module.addImport(
                "gdk_x11",
                gobject.module("gdkx114"),
            );
        }
    }

    if (self.config.wayland) wayland: {
        // These need to be all be called to note that we need them.
        const wayland_dep_ = b.lazyDependency("wayland", .{});
        const wayland_protocols_dep_ = b.lazyDependency(
            "wayland_protocols",
            .{},
        );
        const plasma_wayland_protocols_dep_ = b.lazyDependency(
            "plasma_wayland_protocols",
            .{},
        );
        const zig_wayland_import_ = b.lazyImport(
            @import("../../build.zig"),
            "zig_wayland",
        );
        const zig_wayland_dep_ = b.lazyDependency("zig_wayland", .{});

        // Unwrap or return, there are no more dependencies below.
        const wayland_dep = wayland_dep_ orelse break :wayland;
        const wayland_protocols_dep = wayland_protocols_dep_ orelse break :wayland;
        const plasma_wayland_protocols_dep = plasma_wayland_protocols_dep_ orelse break :wayland;
        const zig_wayland_import = zig_wayland_import_ orelse break :wayland;
        const zig_wayland_dep = zig_wayland_dep_ orelse break :wayland;

        const Scanner = zig_wayland_import.Scanner;
        const scanner = Scanner.create(zig_wayland_dep.builder, .{
            .wayland_xml = wayland_dep.path("protocol/wayland.xml"),
            .wayland_protocols = wayland_protocols_dep.path(""),
        });

        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/blur.xml"),
        );
        // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398
        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/server-decoration.xml"),
        );
        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/slide.xml"),
        );
        scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");

        scanner.generate("wl_compositor", 1);
        scanner.generate("org_kde_kwin_blur_manager", 1);
        scanner.generate("org_kde_kwin_server_decoration_manager", 1);
        scanner.generate("org_kde_kwin_slide_manager", 1);
        scanner.generate("xdg_activation_v1", 1);

        step.root_module.addImport("wayland", b.createModule(.{
            .root_source_file = scanner.result,
        }));
        if (gobject_) |gobject| step.root_module.addImport(
            "gdk_wayland",
            gobject.module("gdkwayland4"),
        );

        if (b.lazyDependency("gtk4_layer_shell", .{
            .target = target,
            .optimize = optimize,
        })) |gtk4_layer_shell| {
            const layer_shell_module = gtk4_layer_shell.module("gtk4-layer-shell");
            if (gobject_) |gobject| layer_shell_module.addImport(
                "gtk",
                gobject.module("gtk4"),
            );
            step.root_module.addImport(
                "gtk4-layer-shell",
                layer_shell_module,
            );

            // IMPORTANT: gtk4-layer-shell must be linked BEFORE
            // wayland-client, as it relies on shimming libwayland's APIs.
            if (b.systemIntegrationOption("gtk4-layer-shell", .{})) {
                step.linkSystemLibrary2("gtk4-layer-shell-0", dynamic_link_opts);
            } else {
                // gtk4-layer-shell *must* be dynamically linked,
                // so we don't add it as a static library
                const shared_lib = gtk4_layer_shell.artifact("gtk4-layer-shell");
                b.installArtifact(shared_lib);
                step.linkLibrary(shared_lib);
            }
        }

        step.linkSystemLibrary2("wayland-client", dynamic_link_opts);
    }

    {
        // Get our gresource c/h files and add them to our build.
        const dist = gtkNgDistResources(b);
        step.addCSourceFile(.{ .file = dist.resources_c.path(b), .flags = &.{} });
        step.addIncludePath(dist.resources_h.path(b).dirname());
    }
}

/// Add only the dependencies required for `Config.simd` enabled. This also
/// adds all the simd source files for compilation.
pub fn addSimd(
    b: *std.Build,
    m: *std.Build.Module,
    static_libs: ?*LazyPathList,
) !void {
    const target = m.resolved_target.?;
    const optimize = m.optimize.?;

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        m.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
        })) |simdutf_dep| {
            m.linkLibrary(simdutf_dep.artifact("simdutf"));
            if (static_libs) |v| try v.append(
                b.allocator,
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Highway
    if (b.systemIntegrationOption("highway", .{ .default = false })) {
        m.linkSystemLibrary("libhwy", dynamic_link_opts);
    } else {
        if (b.lazyDependency("highway", .{
            .target = target,
            .optimize = optimize,
        })) |highway_dep| {
            m.linkLibrary(highway_dep.artifact("highway"));
            if (static_libs) |v| try v.append(
                b.allocator,
                highway_dep.artifact("highway").getEmittedBin(),
            );
        }
    }

    // utfcpp - This is used as a dependency on our hand-written C++ code
    if (b.lazyDependency("utfcpp", .{
        .target = target,
        .optimize = optimize,
    })) |utfcpp_dep| {
        m.linkLibrary(utfcpp_dep.artifact("utfcpp"));
        if (static_libs) |v| try v.append(
            b.allocator,
            utfcpp_dep.artifact("utfcpp").getEmittedBin(),
        );
    }

    // SIMD C++ files
    m.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX10_2: c_int = 1 << 3;
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX10_2 | HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;

        m.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = if (target.result.cpu.arch == .x86_64) &.{
                b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
            } else &.{},
        });
    }
}

/// Creates the resources that can be prebuilt for our dist build.
pub fn gtkNgDistResources(
    b: *std.Build,
) struct {
    resources_c: DistResource,
    resources_h: DistResource,
} {
    const gresource = @import("../apprt/gtk/build/gresource.zig");
    const gresource_xml = gresource_xml: {
        const xml_exe = b.addExecutable(.{
            .name = "generate_gresource_xml",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/gtk/build/gresource.zig"),
                .target = b.graph.host,
            }),
        });
        const xml_run = b.addRunArtifact(xml_exe);

        // Run our blueprint compiler across all of our blueprint files.
        const blueprint_exe = b.addExecutable(.{
            .name = "gtk_blueprint_compiler",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/gtk/build/blueprint.zig"),
                .target = b.graph.host,
            }),
        });
        blueprint_exe.linkLibC();
        blueprint_exe.linkSystemLibrary2("gtk4", dynamic_link_opts);
        blueprint_exe.linkSystemLibrary2("libadwaita-1", dynamic_link_opts);

        for (gresource.blueprints) |bp| {
            const blueprint_run = b.addRunArtifact(blueprint_exe);
            blueprint_run.addArgs(&.{
                b.fmt("{d}", .{bp.major}),
                b.fmt("{d}", .{bp.minor}),
            });
            const ui_file = blueprint_run.addOutputFileArg(b.fmt(
                "{d}.{d}/{s}.ui",
                .{
                    bp.major,
                    bp.minor,
                    bp.name,
                },
            ));
            blueprint_run.addFileArg(b.path(b.fmt(
                "{s}/{d}.{d}/{s}.blp",
                .{
                    gresource.ui_path,
                    bp.major,
                    bp.minor,
                    bp.name,
                },
            )));

            xml_run.addFileArg(ui_file);
        }

        break :gresource_xml xml_run.captureStdOut();
    };

    const generate_c = b.addSystemCommand(&.{
        "glib-compile-resources",
        "--c-name",
        "ghostty",
        "--generate-source",
        "--target",
    });
    const resources_c = generate_c.addOutputFileArg("ghostty_resources.c");
    generate_c.addFileArg(gresource_xml);
    for (gresource.file_inputs) |path| {
        generate_c.addFileInput(b.path(path));
    }

    const generate_h = b.addSystemCommand(&.{
        "glib-compile-resources",
        "--c-name",
        "ghostty",
        "--generate-header",
        "--target",
    });
    const resources_h = generate_h.addOutputFileArg("ghostty_resources.h");
    generate_h.addFileArg(gresource_xml);
    for (gresource.file_inputs) |path| {
        generate_h.addFileInput(b.path(path));
    }

    return .{
        .resources_c = .{
            .dist = "src/apprt/gtk/ghostty_resources.c",
            .generated = resources_c,
        },
        .resources_h = .{
            .dist = "src/apprt/gtk/ghostty_resources.h",
            .generated = resources_h,
        },
    };
}

pub fn addUucode(
    self: *const SharedDeps,
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    if (b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .tables_path = self.uucode_tables,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    })) |dep| {
        module.addImport("uucode", dep.module("uucode"));
    }
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
