const SharedDeps = @This();

const std = @import("std");
const builtin = @import("builtin");

const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const MetallibStep = @import("MetallibStep.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");
const DistResource = @import("GhosttyDist.zig").Resource;
const gtk_helpers = @import("gtk.zig");
const translate_c = @import("translate_c");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
metallib: ?*MetallibStep,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,
uucode_tables: std.Build.LazyPath,

/// Singleton uucode module, instantiated once in `init` and reused
/// everywhere so that ghostty and vaxis share the same compiled tables in
/// each final binary instead of each linking its own copy.
///
/// Sharing one instance is also a hard requirement (not just an
/// optimization) for Zig 0.16's strict module model. `SharedDeps.add` runs
/// many times across different (target, optimize) tuples (macos-aarch64,
/// macos-x86_64, ios-aarch64, Debug + ReleaseFast, etc.), and on each
/// call we have to wire uucode into both the step's root module and into
/// vaxis_mod (because vaxis's `Parser.zig` does `@import("uucode")` and
/// we pass `external_uucode = true` to vaxis's build.zig so vaxis doesn't
/// instantiate its own uucode dep). If those two import bindings ever
/// resolve to *different* `*Module` pointers within a single Compile
/// step's analysis, Zig fails with:
///
///     vaxis/src/Parser.zig: file exists in modules 'uucode' and 'uucode0'
///
/// because all those uucode module instances share the same physical
/// `uucode/src/root.zig` file on disk, and Zig requires every file to belong
/// to exactly one module within a Compile graph.
///
/// The natural way to keep them the same would be to call
/// `b.lazyDependency("uucode", .{ .tables_path, .build_config_path })`
/// from each call site and let Zig's dependency cache deduplicate
/// identical args. That fails because of a bug in Zig's
/// `userLazyPathsAreTheSame` (Build.zig) where the `.src_path` and
/// `.generated` equality checks are inverted: `if (std.mem.eql(...))
/// return false` instead of `if (!std.mem.eql(...)) return false`. The
/// dep cache key therefore always misses whenever any arg is a
/// `b.path(...)` LazyPath, so each call returns a fresh `*Dependency`
/// with a fresh `*Module`. Hoisting the dep into one eager
/// `b.dependency` call here sidesteps the cache entirely.
///
/// This conflict is independent of whether vaxis itself is acquired as a
/// singleton or per-target dep.
uucode_mod: *std.Build.Module,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    const uucode_tables = blk: {
        const uucode = b.dependency("uucode", .{
            .build_config_path = b.path("src/build/uucode_config.zig"),
        });

        break :blk uucode.namedLazyPath("tables.zig");
    };

    // Instantiate the singleton uucode module that both ghostty and vaxis
    // import. See the doc comment on `uucode_mod`.
    const uucode_mod = b.dependency("uucode", .{
        .tables_path = uucode_tables,
        .build_config_path = b.path("src/build/uucode_config.zig"),
    }).module("uucode");

    // Re-export the uucode module so that Zig programs that embed libgtostty-vt
    // can use it. This is necessary to use libraries like libvaxis in
    // the embedding program that need uucode as well (libvaxis provides
    // -Dexternal_uucode for this).
    try b.modules.put(b.allocator, b.dupe("uucode"), uucode_mod);

    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b, uucode_tables),
        .framedata = try .init(b),
        .uucode_tables = uucode_tables,
        .uucode_mod = uucode_mod,

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
    // And this lets other non-platform-specific targets like `-Demit-lib-vt`
    // cross-compile properly.
    if (!builtin.target.os.tag.isDarwin() and
        self.config.target.result.os.tag.isDarwin())
    {
        return static_libs;
    }

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Every exe needs the terminal options
    self.config.terminalOptions(.ghostty, optimize).add(b, step.root_module);

    // Every exe needs the uucode module
    step.root_module.addImport("uucode", self.uucode_mod);

    // C imports for locale constants and functions
    try translate_c.addImportToModule(b, "locale-c", step.root_module, .{
        .source = .{ .file = b.path("src/os/locale.c") },
        .target = target,
        .optimize = optimize,
    });

    // C imports needed to manage/create PTYs
    switch (target.result.os.tag) {
        .freebsd,
        .linux,
        .macos,
        => {
            try translate_c.addImportToModule(b, "pty-c", step.root_module, .{
                .source = .{ .file = b.path("src/pty.c") },
                .target = target,
                .optimize = optimize,
            });
        },
        else => {},
    }

    // POSIX C imports that are used throughout Ghostty on a general basis.
    // (note: errno is C stdlib but we just include it here because that's
    // where it's generally included otherwise)
    try translate_c.addImportToModule(b, "posix_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "errno.h" },
            .{ .path = "pwd.h" },
            .{ .path = "signal.h" },
            .{ .path = "sys/types.h" },
            .{ .path = "unistd.h" },
        } } },
        .target = target,
        .optimize = optimize,
    });

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
            step.root_module.linkSystemLibrary("bzip2", dynamic_link_opts);
            step.root_module.linkSystemLibrary("freetype2", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(freetype_dep.artifact("freetype"));
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
                step.root_module.linkSystemLibrary("harfbuzz", dynamic_link_opts);
            } else {
                step.root_module.linkLibrary(harfbuzz_dep.artifact("harfbuzz"));
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
                step.root_module.linkSystemLibrary("fontconfig", dynamic_link_opts);
            } else {
                step.root_module.linkLibrary(fontconfig_dep.artifact("fontconfig"));
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
            step.root_module.linkLibrary(libpng_dep.artifact("png"));
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
            step.root_module.linkLibrary(zlib_dep.artifact("z"));
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
            step.root_module.linkSystemLibrary("oniguruma", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(oniguruma_dep.artifact("oniguruma"));
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
            step.root_module.linkSystemLibrary("glslang", dynamic_link_opts);
            step.root_module.linkSystemLibrary(
                "glslang-default-resource-limits",
                dynamic_link_opts,
            );
        } else {
            step.root_module.linkLibrary(glslang_dep.artifact("glslang"));
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
            step.root_module.linkSystemLibrary("spirv-cross-c-shared", dynamic_link_opts);
        } else {
            step.root_module.linkLibrary(spirv_cross_dep.artifact("spirv_cross"));
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
            step.root_module.linkLibrary(sentry_dep.artifact("sentry"));
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
        if (std.Io.Dir.accessAbsolute(b.graph.io, path, .{})) {
            step.root_module.addLibraryPath(.{ .cwd_relative = path });
        } else |_| {}
    }

    // nothings/stb headers
    try translate_c.addImportToModule(b, "stb_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{
            .{ .path = "stb_image.h" },
            .{ .path = "stb_image_resize.h" },
        } } },
        .target = target,
        .optimize = optimize,
        .include_paths = &.{b.path("src/stb")},
    });

    // C files
    step.root_module.link_libc = true;
    step.root_module.addIncludePath(b.path("src/stb"));
    // Disable ubsan for MSVC: Zig's ubsan runtime cannot be bundled
    // on Windows (LNK4229), leaving __ubsan_handle_* unresolved when
    // the static archive is consumed by an external linker.
    step.root_module.addCSourceFiles(.{
        .files = &.{"src/stb/stb.c"},
        .flags = if (step.rootModuleTarget().abi == .msvc)
            &.{ "-fno-sanitize=undefined", "-fno-sanitize-trap=undefined" }
        else
            &.{},
    });
    if (step.rootModuleTarget().os.tag == .linux) {
        step.root_module.addIncludePath(b.path("src/apprt/gtk"));
    }

    // libcpp is required for various dependencies. On MSVC, we must
    // not use linkLibCpp because Zig unconditionally passes -nostdinc++
    // and then adds its bundled libc++/libc++abi include paths, which
    // conflict with MSVC's own C++ runtime headers. The MSVC SDK
    // include directories (already added via linkLibC above) contain
    // both C and C++ headers, so linkLibCpp is not needed.
    if (step.rootModuleTarget().abi != .msvc) {
        step.root_module.link_libcpp = true;
    }

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
    if (b.lazyDependency("vaxis", .{
        .target = target,
        .optimize = optimize,
        .external_uucode = true,
    })) |dep| {
        const vaxis = dep.module("vaxis");
        step.root_module.addImport("vaxis", vaxis);
        vaxis.addImport("uucode", self.uucode_mod);
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
            step.root_module.linkLibrary(
                macos_dep.artifact("macos"),
            );
            try static_libs.append(
                b.allocator,
                macos_dep.artifact("macos").getEmittedBin(),
            );
        }

        if (self.config.renderer == .opengl) {
            step.root_module.linkFramework("OpenGL", .{});
        }

        // Apple platforms do not include libc libintl so we bundle it.
        // This is LGPL but since our source code is open source we are
        // in compliance with the LGPL since end users can modify this
        // build script to replace the bundled libintl with their own.
        if (b.lazyDependency("libintl", .{
            .target = target,
            .optimize = optimize,
        })) |libintl_dep| {
            step.root_module.linkLibrary(libintl_dep.artifact("intl"));
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
        step.root_module.linkLibrary(dep.artifact("dcimgui"));
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
        step.root_module.addIncludePath(b.path("vendor/glad/include/"));
        step.root_module.addCSourceFile(.{
            .file = b.path("vendor/glad/src/gl.c"),
            .flags = &.{},
        });

        // Link EGL for GTK.
        if (self.config.app_runtime == .gtk) {
            step.root_module.addCSourceFile(.{
                .file = b.path("vendor/glad/src/glad_egl.c"),
                .flags = &.{},
            });
            step.root_module.linkSystemLibrary("egl", dynamic_link_opts);
        }

        // When we're targeting flatpak we ALWAYS link GTK so we
        // get access to glib for dbus.
        if (self.config.flatpak) {
            step.root_module.linkSystemLibrary("gtk4", dynamic_link_opts);

            // We need to translate gio headers too
            try translate_c.addImportToModule(b, "gio_c", step.root_module, .{
                .source = .{ .includes = .{ .files = &.{
                    .{ .path = "gio/gio.h" },
                    .{ .path = "gio/gunixfdlist.h" },
                } } },
                .target = target,
                .optimize = optimize,
                .link_system_libs = &.{"gio-2.0"},
            });
        }

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
            .{ "glibunix", "glibunix2" },
            .{ "gobject", "gobject2" },
            .{ "gtk", "gtk4" },
            .{ "xlib", "xlib2" },
        };
        inline for (gobject_imports) |import| {
            const name, const module = import;
            step.root_module.addImport(name, gobject.module(module));
        }
    }

    // GTK C translation
    try translate_c.addImportToModule(b, "gtk_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{.{ .path = "gtk/gtk.h" }} } },
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{"gtk4"},
    });

    // Adwaita C translation
    try translate_c.addImportToModule(b, "adw_c", step.root_module, .{
        .source = .{ .includes = .{ .files = &.{.{ .path = "adwaita.h" }} } },
        .target = target,
        .optimize = optimize,
        .link_system_libs = &.{"libadwaita-1"},
    });

    if (self.config.x11) {
        // X11 headers
        try translate_c.addImportToModule(b, "x11_c", step.root_module, .{
            .source = .{ .includes = .{ .files = &.{
                .{ .path = "X11/Xlib.h" },
                .{ .path = "X11/Xatom.h" },
                .{ .path = "X11/XKBlib.h" },
            } } },
            .target = target,
            .optimize = optimize,
            .link_system_libs = &.{"X11"},
        });

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

        // FIXME: replace with `zxdg_decoration_v1` once GTK merges https://gitlab.gnome.org/GNOME/gtk/-/merge_requests/6398
        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/server-decoration.xml"),
        );
        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/slide.xml"),
        );
        scanner.addCustomProtocol(
            plasma_wayland_protocols_dep.path("src/protocols/kde-output-order-v1.xml"),
        );
        scanner.addSystemProtocol("staging/xdg-activation/xdg-activation-v1.xml");
        scanner.addSystemProtocol("staging/ext-background-effect/ext-background-effect-v1.xml");
        scanner.addCustomProtocol(
            b.path("src/apprt/gtk/winproto/wayland/protocols/vicinae-hotkey-v1.xml"),
        );

        scanner.generate("wl_compositor", 1);
        // Only referenced by vicinae_hotkey_manager_v1.bind (nullable arg).
        scanner.generate("wl_seat", 1);
        scanner.generate("org_kde_kwin_server_decoration_manager", 1);
        scanner.generate("org_kde_kwin_slide_manager", 1);
        scanner.generate("kde_output_order_v1", 1);
        scanner.generate("xdg_activation_v1", 1);
        scanner.generate("ext_background_effect_manager_v1", 1);
        scanner.generate("vicinae_hotkey_manager_v1", 1);

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
            if (gobject_) |gobject| {
                layer_shell_module.addImport("gtk", gobject.module("gtk4"));
                layer_shell_module.addImport("gdk", gobject.module("gdk4"));
            }
            step.root_module.addImport(
                "gtk4-layer-shell",
                layer_shell_module,
            );

            // IMPORTANT: gtk4-layer-shell must be linked BEFORE
            // wayland-client, as it relies on shimming libwayland's APIs.
            if (b.systemIntegrationOption("gtk4-layer-shell", .{})) {
                step.root_module.linkSystemLibrary("gtk4-layer-shell-0", dynamic_link_opts);
            } else {
                // gtk4-layer-shell *must* be dynamically linked,
                // so we don't add it as a static library
                const shared_lib = gtk4_layer_shell.artifact("gtk4-layer-shell");
                b.installArtifact(shared_lib);
                step.root_module.linkLibrary(shared_lib);
            }
        }

        step.root_module.linkSystemLibrary("wayland-client", dynamic_link_opts);
    }

    {
        // Get our gresource c/h files and add them to our build.
        const dist = gtkNgDistResources(b);
        const translated = try translate_c.init(b, .{
            .source = .{ .includes = .{
                .generated_name = "ghostty_gtk_resources_c.h",
                .files = &.{.{ .path = "ghostty_resources.h" }},
            } },
            .target = target,
            .optimize = optimize,
            .link_system_libs = &.{"glib-2.0"},
            .include_paths = &.{dist.resources_h.path(b).dirname()},
        });
        translated.mod.addCSourceFile(.{ .file = dist.resources_c.path(b), .flags = &.{} });
        step.root_module.addImport("ghostty_gtk_resources", translated.mod);
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
    const system_highway = b.systemIntegrationOption("highway", .{ .default = false });

    // Simdutf
    if (b.systemIntegrationOption("simdutf", .{})) {
        m.linkSystemLibrary("simdutf", dynamic_link_opts);
    } else {
        if (b.lazyDependency("simdutf", .{
            .target = target,
            .optimize = optimize,
            .no_libcxx = true,
        })) |simdutf_dep| {
            m.linkLibrary(simdutf_dep.artifact("simdutf"));
            if (static_libs) |v| try v.append(
                b.allocator,
                simdutf_dep.artifact("simdutf").getEmittedBin(),
            );
        }
    }

    // Highway
    if (system_highway) {
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

    // SIMD C++ files
    m.addIncludePath(b.path("src"));
    {
        // From hwy/detect_targets.h
        const HWY_AVX10_2: c_int = 1 << 3;
        const HWY_AVX3_SPR: c_int = 1 << 4;
        const HWY_AVX3_ZEN4: c_int = 1 << 6;
        const HWY_AVX3_DL: c_int = 1 << 7;
        const HWY_AVX3: c_int = 1 << 8;

        var flags: std.ArrayListUnmanaged([]const u8) = .empty;

        // Zig 0.13 bug: https://github.com/ziglang/zig/issues/20414
        // To workaround this we just disable AVX512 support completely.
        // The performance difference between AVX2 and AVX512 is not
        // significant for our use case and AVX512 is very rare on consumer
        // hardware anyways.
        const HWY_DISABLED_TARGETS: c_int = HWY_AVX10_2 | HWY_AVX3_SPR | HWY_AVX3_ZEN4 | HWY_AVX3_DL | HWY_AVX3;
        if (target.result.cpu.arch == .x86_64) try flags.append(
            b.allocator,
            b.fmt("-DHWY_DISABLED_TARGETS={}", .{HWY_DISABLED_TARGETS}),
        );

        // MSVC requires explicit std specification otherwise these
        // are guarded, at least on Windows 2025. Doing it unconditionally
        // doesn't cause any issues on other platforms and ensures we get
        // C++17 support on MSVC.
        try flags.append(
            b.allocator,
            "-std=c++17",
        );

        // Keep our SIMD sources in the same Highway header mode as the
        // vendored package build so HWY's inline dispatch/runtime helpers
        // have a consistent ABI.
        if (!system_highway) try flags.append(
            b.allocator,
            "-DHWY_NO_LIBCXX",
        );

        // When using the vendored simdutf, build its headers in no-libcxx
        // mode so we don't need C++ standard library headers at all.
        // System simdutf headers may not support this define.
        if (!b.systemIntegrationOption("simdutf", .{})) try flags.append(
            b.allocator,
            "-DSIMDUTF_NO_LIBCXX",
        );

        // Disable ubsan for Windows C/C++ objects to avoid undefined
        // __ubsan_handle_* references. The Zig libraries on Windows don't
        // currently bundle a matching UBSan runtime for these objects in
        // our build configurations (this affects both MSVC and GNU ABIs).
        if (target.result.os.tag == .windows) try flags.appendSlice(b.allocator, &.{
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
        });
        if (target.result.abi == .msvc) try flags.appendSlice(b.allocator, &.{
            // -fno-autolink also drops UCRT's /alternatename fallback.
            "-D_Avx2WmemEnabledWeakValue=_Avx2WmemEnabled",
            "-fno-autolink",
        });

        m.addCSourceFiles(.{
            .files = &.{
                "src/simd/base64.cpp",
                "src/simd/codepoint_width.cpp",
                "src/simd/index_of.cpp",
                "src/simd/vt.cpp",
            },
            .flags = flags.items,
        });
    }
}

pub const GtkNgResources = struct {
    resources_c: DistResource,
    resources_h: DistResource,
};

/// Memoized result of `gtkNgDistResources`, keyed on the `*std.Build`.
/// The configure pass is single-threaded, so a file-scope map is enough.
var gtk_ng_resources: std.AutoHashMapUnmanaged(*std.Build, GtkNgResources) = .empty;

/// Creates the resources that can be prebuilt for our dist build.
///
/// Memoized because `add` calls this once per artifact that links GTK and
/// `GhosttyDist` calls it too. Each call used to build its own copy of the
/// whole pipeline, and since Zig's cache hashes input *paths* as well as
/// contents, the copies did not share results downstream.
pub fn gtkNgDistResources(b: *std.Build) GtkNgResources {
    if (gtk_ng_resources.get(b)) |cached| return cached;
    const resources = gtkNgDistResourcesUncached(b);
    gtk_ng_resources.put(b.allocator, b, resources) catch @panic("OOM");
    return resources;
}

fn gtkNgDistResourcesUncached(b: *std.Build) GtkNgResources {
    const gresource = @import("../apprt/gtk/build/gresource.zig");
    const gresource_file_inputs = gresource.file_inputs;

    // Compile every blueprint into one directory laid out as
    // `{major}.{minor}/{name}.ui`, so that `glib-compile-resources` gets a
    // single `--sourcedir` and the gresource XML needs no absolute paths.
    //
    // `blueprint-compiler` is run directly, not through a compiled wrapper.
    // A run step hashes the bytes of the executable it runs, and a Zig
    // binary does not relink to the same bytes (anonymous declaration
    // numbering depends on compilation history), so a branch switch that
    // touched the wrapper would move every `.ui`, re-run the gresource
    // compiler and recompile the whole app for identical output. Run
    // directly, a `.ui` depends only on its `.blp`.
    const ui_dir = ui_dir: {
        // The version checks, done once. This links libadwaita for the
        // version macros and so relinks as described above, which is
        // harmless: nothing reads its output, the compile steps only
        // depend on it having succeeded.
        const check_exe = b.addExecutable(.{
            .name = "gtk_blueprint_check",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/gtk/build/blueprint.zig"),
                .target = b.graph.host,
                .link_libc = true,
            }),
        });

        // Adwaita headers
        translate_c.addImportToModule(b, "adw_c", check_exe.root_module, .{
            .source = .{ .includes = .{ .files = &.{.{ .path = "adwaita.h" }} } },
            .target = b.graph.host,
            .optimize = .Debug,
            .link_system_libs = &.{"libadwaita-1"},
        }) catch unreachable;

        // The headers have to satisfy the newest blueprint.
        var required: struct { major: u16, minor: u16 } = .{ .major = 0, .minor = 0 };
        for (gresource.blueprints) |bp| {
            if (bp.major > required.major or
                (bp.major == required.major and bp.minor > required.minor))
            {
                required = .{ .major = bp.major, .minor = bp.minor };
            }
        }

        const check_run = b.addRunArtifact(check_exe);
        check_run.addArgs(&.{
            b.fmt("{d}", .{required.major}),
            b.fmt("{d}", .{required.minor}),
        });
        // An output, so the check is cached instead of run every build.
        _ = check_run.addOutputFileArg("blueprint-check.stamp");

        // `WriteFile` hashes source paths as well as bytes, but these paths
        // only move when a `.blp` changes, which reaches the gresource
        // compiler regardless since the `.blp` files are its inputs too.
        const ui_files = b.addWriteFiles();
        for (gresource.blueprints) |bp| {
            const sub_path = b.fmt("{d}.{d}/{s}.ui", .{
                bp.major,
                bp.minor,
                bp.name,
            });

            const compile = b.addSystemCommand(&.{
                "blueprint-compiler",
                "compile",
                "--output",
            });
            const ui_file = compile.addOutputFileArg(sub_path);
            compile.addFileArg(b.path(b.fmt(
                "{s}/{d}.{d}/{s}.blp",
                .{
                    gresource.ui_path,
                    bp.major,
                    bp.minor,
                    bp.name,
                },
            )));
            compile.step.dependOn(&check_run.step);

            _ = ui_files.addCopyFile(ui_file, sub_path);
        }

        break :ui_dir ui_files.getDirectory();
    };

    // The gresource XML. Its only inputs are source tree files, so its path
    // and contents are stable. The compiled `.ui` files are deliberately
    // not inputs: it names them relative to the `--sourcedir` below, so no
    // cache path ever appears in it.
    const gresource_xml = gresource_xml: {
        const xml_exe = b.addExecutable(.{
            .name = "generate_gresource_xml",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/apprt/gtk/build/gresource.zig"),
                .target = b.graph.host,
            }),
        });
        const xml_run = b.addRunArtifact(xml_exe);

        // Named in the XML by relative path; the program only `access`es them.
        for (gresource.file_inputs) |path| xml_run.addFileInput(b.path(path));

        break :gresource_xml xml_run.captureStdOut(.{});
    };

    const generate = struct {
        fn step(
            bb: *std.Build,
            dir: std.Build.LazyPath,
            xml: std.Build.LazyPath,
            mode: []const u8,
            name: []const u8,
        ) std.Build.LazyPath {
            const run = bb.addSystemCommand(&.{"glib-compile-resources"});

            // The build root for the icons and CSS, the collected directory
            // for the compiled blueprints. Any `--sourcedir` replaces the
            // default of the working directory, so the root must be named.
            run.addArgs(&.{ "--sourcedir", "." });
            run.addArg("--sourcedir");
            run.addDirectoryArg(dir);

            run.addArgs(&.{ "--c-name", "ghostty", mode, "--target" });
            const out = run.addOutputFileArg(name);
            run.addFileArg(xml);

            // `glib-compile-resources` reads these itself, so they are
            // inputs here as well as of the XML step.
            for (gresource_file_inputs) |path| run.addFileInput(bb.path(path));

            return out;
        }
    }.step;

    return .{
        .resources_c = .{
            .dist = "src/apprt/gtk/ghostty_resources.c",
            .generated = generate(
                b,
                ui_dir,
                gresource_xml,
                "--generate-source",
                "ghostty_resources.c",
            ),
        },
        .resources_h = .{
            .dist = "src/apprt/gtk/ghostty_resources.h",
            .generated = generate(
                b,
                ui_dir,
                gresource_xml,
                "--generate-header",
                "ghostty_resources.h",
            ),
        },
    };
}

// For dynamic linking, we prefer dynamic linking and to search by
// mode first. Mode first will search all paths for a dynamic library
// before falling back to static.
const dynamic_link_opts: std.Build.Module.LinkSystemLibraryOptions = .{
    .preferred_link_mode = .dynamic,
    .search_strategy = .mode_first,
};
