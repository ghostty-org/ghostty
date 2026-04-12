/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const ApprtRuntime = @import("../apprt/runtime.zig").Runtime;
const FontBackend = @import("../font/backend.zig").Backend;
const RendererBackend = @import("../renderer/backend.zig").Backend;
const TerminalBuildOptions = @import("../terminal/build_options.zig").Options;
const WasmTarget = @import("../os/wasm/target.zig").Target;
const expandPath = @import("../os/path.zig").expand;

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: ApprtRuntime = .win32,
renderer: RendererBackend = .opengl,
font_backend: FontBackend = .freetype,

/// Feature flags
x11: bool = false,
wayland: bool = false,
sentry: bool = true,
simd: bool = true,
i18n: bool = true,
custom_shaders: bool = false,
wasm_shared: bool = true,

/// Ghostty exe properties
exe_entrypoint: ExeEntrypoint = .ghostty,
version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },

/// Binary properties
pie: bool = false,
strip: bool = false,
patch_rpath: ?[]const u8 = null,

/// Artifacts
flatpak: bool = false,
snap: bool = false,
emit_bench: bool = false,
emit_docs: bool = false,
emit_exe: bool = false,
emit_helpgen: bool = false,
emit_lib_vt: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_themes: bool = false,
emit_webdata: bool = false,
emit_unicode_table_gen: bool = false,

/// True when Ghostty is being built as a dependency of another project
/// rather than as the root project.
is_dep: bool = false,

/// Environmental properties
env: std.process.EnvMap,

pub fn init(b: *std.Build, appVersion: []const u8) !Config {
    // Setup our standard Zig target and optimize options, i.e.
    // `-Doptimize` and `-Dtarget`.
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // On Windows, default to the MSVC ABI so that produced COFF
        // objects (including compiler_rt) are compatible with the MSVC
        // linker. Zig defaults to the GNU ABI which produces objects
        // with invalid COMDAT sections that MSVC rejects (LNK1143).
        // Only override when no explicit ABI was requested.
        if (result.result.os.tag == .windows and
            result.query.abi == null)
        {
            var query = result.query;
            query.abi = .msvc;
            result = b.resolveTargetQuery(query);
        }

        break :target result;
    };

    // Detect if Ghostty is a dependency of another project.
    // dep_prefix is non-empty when this build is running as a dependency.
    const is_dep = b.dep_prefix.len > 0;

    // This is set to true when we're building a system package. For now
    // this is trivially detected using the "system_package_mode" bool
    // but we may want to make this more sophisticated in the future.
    const system_package = b.graph.system_package_mode;

    // This specifies our target wasm runtime. For now only one semi-usable
    // one exists so this is hardcoded.
    const wasm_target: WasmTarget = .browser;

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    errdefer env.deinit();

    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = wasm_target,
        .is_dep = is_dep,
        .env = env,
    };

    //---------------------------------------------------------------
    // Comptime Interfaces
    config.font_backend = b.option(
        FontBackend,
        "font-backend",
        "The font backend to use for discovery and rasterization.",
    ) orelse FontBackend.default(target.result, wasm_target);

    config.app_runtime = b.option(
        ApprtRuntime,
        "app-runtime",
        "The app runtime to use. This fork supports Win32 only for app builds.",
    ) orelse ApprtRuntime.default(target.result);
    if (config.app_runtime == .win32 and target.result.os.tag != .windows) {
        return error.WindowsOnlyAppRuntimeRequiresWindowsTarget;
    }

    config.renderer = b.option(
        RendererBackend,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse RendererBackend.default(target.result, wasm_target);

    //---------------------------------------------------------------
    // Feature Flags

    // These remain in build_options for shared code paths, but the
    // Windows-only fork no longer exposes them as user-facing build flags.
    config.flatpak = false;

    config.snap = false;

    config.sentry = b.option(
        bool,
        "sentry",
        "Build with Sentry crash reporting. Enabled by default for Windows in this fork.",
    ) orelse sentry: {
        switch (target.result.os.tag) {
            .windows => break :sentry true,
            else => break :sentry false,
        }
    };

    config.simd = b.option(
        bool,
        "simd",
        "Build with SIMD-accelerated code paths. Results in significant performance improvements.",
    ) orelse simd: {
        // We can't build our SIMD dependencies for Wasm. Note that we may
        // still use SIMD features in the Wasm-builds.
        if (target.result.cpu.arch.isWasm()) break :simd false;

        break :simd true;
    };

    config.wayland = false;

    config.x11 = false;

    config.i18n = b.option(
        bool,
        "i18n",
        "Enables gettext-based internationalization.",
    ) orelse switch (target.result.os.tag) {
        .windows => false,
        else => false,
    };

    config.custom_shaders = b.option(
        bool,
        "custom-shaders",
        "Enable custom shader compilation support. Disabled by default in the Windows-only fork to keep default app builds lighter.",
    ) orelse false;

    //---------------------------------------------------------------
    // Ghostty Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, the Windows-only fork uses a generic dev version. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        const app_version = try std.SemanticVersion.parse(appVersion);

        break :version .{
            .major = app_version.major,
            .minor = app_version.minor,
            .patch = app_version.patch,
            .pre = "dev",
            .build = if (is_dep) null else "windows",
        };
    };

    //---------------------------------------------------------------
    // Binary Properties

    _ = b.option(
        []const u8,
        "patch-rpath",
        "Deprecated in the Windows-only fork. Retained as a disabled compatibility flag.",
    );
    config.patch_rpath = null;

    config.pie = b.option(
        bool,
        "pie",
        "Build a Position Independent Executable. Default true for system packages.",
    ) orelse system_package;

    config.strip = b.option(
        bool,
        "strip",
        "Strip the final executable. Default true for fast and small releases",
    ) orelse switch (optimize) {
        .Debug => false,
        .ReleaseSafe => false,
        .ReleaseFast, .ReleaseSmall => true,
    };

    //---------------------------------------------------------------
    // Artifacts to Emit

    config.emit_lib_vt = b.option(
        bool,
        "emit-lib-vt",
        "Set defaults for a libghostty-vt-only build in the Windows-only fork.",
    ) orelse false;

    config.emit_exe = b.option(
        bool,
        "emit-exe",
        "Build and install main executables with 'build'",
    ) orelse !config.emit_lib_vt;

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
    ) orelse false;

    config.emit_unicode_table_gen = b.option(
        bool,
        "emit-unicode-table-gen",
        "Build and install executables that generate unicode tables with 'build'",
    ) orelse false;

    config.emit_bench = b.option(
        bool,
        "emit-bench",
        "Build and install the benchmark executables.",
    ) orelse false;

    config.emit_helpgen = b.option(
        bool,
        "emit-helpgen",
        "Build and install the helpgen executable.",
    ) orelse false;

    config.emit_docs = b.option(
        bool,
        "emit-docs",
        "Build and install auto-generated documentation (requires pandoc)",
    ) orelse emit_docs: {
        // If we are emitting any other artifacts then we default to false.
        if (config.emit_bench or
            config.emit_test_exe or
            config.emit_helpgen or
            config.emit_lib_vt) break :emit_docs false;

        // We always emit docs in system package mode.
        if (system_package) break :emit_docs true;

        // We only default to true if we can find pandoc.
        const path = expandPath(b.allocator, "pandoc") catch
            break :emit_docs false;
        defer if (path) |p| b.allocator.free(p);
        break :emit_docs path != null;
    };

    config.emit_terminfo = b.option(
        bool,
        "emit-terminfo",
        "Install Ghostty terminfo source file",
    ) orelse switch (target.result.os.tag) {
        .windows => true,
        else => switch (optimize) {
            .Debug => true,
            .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
        },
    };

    config.emit_termcap = b.option(
        bool,
        "emit-termcap",
        "Install Ghostty termcap file",
    ) orelse switch (optimize) {
        .Debug => true,
        .ReleaseSafe, .ReleaseFast, .ReleaseSmall => false,
    };

    config.emit_themes = b.option(
        bool,
        "emit-themes",
        "Install bundled iTerm2-Color-Schemes Ghostty themes",
    ) orelse true;

    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;

    //---------------------------------------------------------------
    // System Packages

    // These are all our dependencies that can be used with system
    // packages if they exist. We set them up here so that we can set
    // their defaults early. The first call configures the integration and
    // subsequent calls just return the configured value. This lets them
    // show up properly in `--help`.

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
                    .default = null,
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

    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "snap", self.snap);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(bool, "simd", self.simd);
    step.addOption(bool, "i18n", self.i18n);
    step.addOption(bool, "custom_shaders", self.custom_shaders);
    step.addOption(ApprtRuntime, "app_runtime", self.app_runtime);
    step.addOption(FontBackend, "font_backend", self.font_backend);
    step.addOption(RendererBackend, "renderer", self.renderer);
    step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
    step.addOption(WasmTarget, "wasm_target", self.wasm_target);
    step.addOption(bool, "wasm_shared", self.wasm_shared);

    // Our version. We also add the string version so we don't need
    // to do any allocations at runtime. This has to be long enough to
    // accommodate realistic large branch names for dev versions.
    var buf: [1024]u8 = undefined;
    step.addOption(std.SemanticVersion, "app_version", self.version);
    step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
        &buf,
        "{f}",
        .{self.version},
    ));
    step.addOption(
        ReleaseChannel,
        "release_channel",
        channel: {
            const pre = self.version.pre orelse break :channel .stable;
            if (pre.len == 0) break :channel .stable;
            break :channel .tip;
        },
    );
}

/// Returns the build options for the terminal module. This assumes a
/// Ghostty executable being built. Callers should modify this as needed.
pub fn terminalOptions(self: *const Config) TerminalBuildOptions {
    return .{
        .artifact = .ghostty,
        .simd = self.simd,
        .oniguruma = true,
        .c_abi = false,
        .version = self.version,
        .slow_runtime_safety = switch (self.optimize) {
            .Debug => true,
            .ReleaseSafe,
            .ReleaseSmall,
            .ReleaseFast,
            => false,
        },
    };
}

/// Returns a baseline CPU target retaining all the other CPU configs.
pub fn baselineTarget(self: *const Config) std.Build.ResolvedTarget {
    // Set our cpu model as baseline. There may need to be other modifications
    // we need to make such as resetting CPU features but for now this works.
    var q = self.target.query;
    q.cpu_model = .baseline;

    // Same logic as build.resolveTargetQuery but we don't need to
    // handle the native case.
    return .{
        .query = q,
        .result = std.zig.system.resolveTargetQuery(q) catch
            @panic("unable to resolve baseline query"),
    };
}

/// Rehydrate our Config from the comptime options. Note that not all
/// options are available at comptime, so look closely at this implementation
/// to see what is and isn't available.
pub fn fromOptions() Config {
    const options = @import("build_options");
    return .{
        // Unused at runtime.
        .optimize = undefined,
        .target = undefined,
        .env = undefined,

        .version = options.app_version,
        .flatpak = options.flatpak,
        .app_runtime = std.meta.stringToEnum(ApprtRuntime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(FontBackend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(RendererBackend, @tagName(options.renderer)).?,
        .snap = options.snap,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
        .i18n = options.i18n,
        .custom_shaders = options.custom_shaders,
    };
}

/// The possible entrypoints for the exe artifact. This has no effect on
/// other artifact types (i.e. lib, wasm_module).
///
/// The whole existence of this enum is to workaround the fact that Zig
/// doesn't allow the main function to be in a file in a subdirctory
/// from the "root" of the module, and I don't want to pollute our root
/// directory with a bunch of individual zig files for each entrypoint.
///
/// Therefore, main.zig uses this to switch between the different entrypoints.
pub const ExeEntrypoint = enum {
    ghostty,
    helpgen,
    mdgen_ghostty_1,
    mdgen_ghostty_5,
    webgen_config,
    webgen_actions,
    webgen_commands,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
