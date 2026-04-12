const SharedDeps = @This();

const std = @import("std");

const Config = @import("Config.zig");
const HelpStrings = @import("HelpStrings.zig");
const UnicodeTables = @import("UnicodeTables.zig");
const GhosttyFrameData = @import("GhosttyFrameData.zig");

config: *const Config,

options: *std.Build.Step.Options,
help_strings: HelpStrings,
unicode_tables: UnicodeTables,
framedata: GhosttyFrameData,
uucode_tables: std.Build.LazyPath,

/// Used to keep track of a list of file sources.
pub const LazyPathList = std.ArrayList(std.Build.LazyPath);

pub fn init(b: *std.Build, cfg: *const Config) !SharedDeps {
    const uucode_tables = b.path("src/build/uucode_tables.zig");

    var result: SharedDeps = .{
        .config = cfg,
        .help_strings = try .init(b, cfg),
        .unicode_tables = try .init(b, cfg, uucode_tables),
        .framedata = try .init(b),
        .uucode_tables = uucode_tables,

        // Setup by retarget
        .options = undefined,
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

    // Every exe gets build options populated
    step.root_module.addOptions("build_options", self.options);

    // Every exe needs the terminal options
    self.config.terminalOptions().add(b, step.root_module);

    // C imports for locale constants and functions
    {
        const c = b.addTranslateC(.{
            .root_source_file = b.path("src/os/locale.c"),
            .target = target,
            .optimize = optimize,
        });
        if (target.result.os.tag.isDarwin()) {
            const libc = try std.zig.LibCInstallation.findNative(.{
                .allocator = b.allocator,
                .target = &target.result,
                .verbose = false,
            });
            c.addSystemIncludePath(.{ .cwd_relative = libc.sys_include_dir.? });
        }
        step.root_module.addImport("locale-c", c.createModule());
    }

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
            .@"enable-coretext" = false,
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

    if (self.config.custom_shaders) {
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
    // on the standard search list.
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

    // libcpp is required for various dependencies. On MSVC, we must
    // not use linkLibCpp because Zig unconditionally passes -nostdinc++
    // and then adds its bundled libc++/libc++abi include paths, which
    // conflict with MSVC's own C++ runtime headers. The MSVC SDK
    // include directories (already added via linkLibC above) contain
    // both C and C++ headers, so linkLibCpp is not needed.
    if (step.rootModuleTarget().abi != .msvc) {
        step.linkLibCpp();
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

    // cimgui
    if (b.lazyDependency("dcimgui", .{
        .target = target,
        .optimize = optimize,
        .freetype = true,
        .@"backend-metal" = false,
        .@"backend-osx" = false,
        .@"backend-opengl3" = true,
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

        switch (self.config.app_runtime) {
            .none => {},
            .win32 => {
                step.linkSystemLibrary2("user32", dynamic_link_opts);
                step.linkSystemLibrary2("gdi32", dynamic_link_opts);
                step.linkSystemLibrary2("opengl32", dynamic_link_opts);
            },
        }
    }

    self.help_strings.addImport(step);
    self.unicode_tables.addImport(step);
    self.framedata.addImport(step);

    return static_libs;
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

        // Disable ubsan for MSVC to avoid undefined references to
        // __ubsan_handle_* symbols that require a runtime we don't link
        // and bundle. Hopefully we can fix this one day since ubsan is nice!
        if (target.result.abi == .msvc) try flags.appendSlice(b.allocator, &.{
            "-fno-sanitize=undefined",
            "-fno-sanitize-trap=undefined",
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

pub fn addUucode(
    self: *const SharedDeps,
    b: *std.Build,
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    _ = self;
    if (b.lazyDependency("uucode", .{
        .target = target,
        .optimize = optimize,
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
