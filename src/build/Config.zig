/// Build configuration. This is the configuration that is populated
/// during `zig build` to control the rest of the build process.
const Config = @This();

const std = @import("std");
const builtin = @import("builtin");

const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const rendererpkg = @import("../renderer.zig");
const Command = @import("../Command.zig");
const XCFramework = @import("GhosttyXCFramework.zig");
const WasmTarget = @import("../os/wasm/target.zig").Target;

const gtk = @import("gtk.zig");
const GitVersion = @import("GitVersion.zig");

/// The version of the next release.
///
/// TODO: When Zig 0.14 is released, derive this from build.zig.zon directly.
/// Until then this MUST match build.zig.zon and should always be the
/// _next_ version to release.
const app_version: std.SemanticVersion = .{ .major = 1, .minor = 1, .patch = 4 };

/// Standard build configuration options.
optimize: std.builtin.OptimizeMode,
target: std.Build.ResolvedTarget,
xcframework_target: XCFramework.Target = .universal,
wasm_target: WasmTarget,

/// Comptime interfaces
app_runtime: apprt.Runtime = .none,
renderer: rendererpkg.Impl = .opengl,
font_backend: font.Backend = .freetype,

/// Feature flags
x11: bool = false,
wayland: bool = false,
sentry: bool = true,
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
emit_bench: bool = false,
emit_docs: bool = false,
emit_helpgen: bool = false,
emit_macos_app: bool = false,
emit_terminfo: bool = false,
emit_termcap: bool = false,
emit_test_exe: bool = false,
emit_xcframework: bool = false,
emit_webdata: bool = false,

/// Environmental properties
env: std.process.EnvMap,

pub fn init(b: *std.Build) !Config {
    // Setup our standard Zig target and optimize options, i.e.
    // `-Doptimize` and `-Dtarget`.
    const optimize = b.standardOptimizeOption(.{});
    const target = target: {
        var result = b.standardTargetOptions(.{});

        // If we're building for macOS and we're on macOS, we need to
        // use a generic target to workaround compilation issues.
        if (result.result.os.tag == .macos and
            builtin.target.os.tag.isDarwin())
        {
            result = genericMacOSTarget(b, result.query.cpu_arch);
        }

        // If we have no minimum OS version, we set the default based on
        // our tag. Not all tags have a minimum so this may be null.
        if (result.query.os_version_min == null) {
            result.query.os_version_min = osVersionMin(result.result.os.tag);
        }

        break :target result;
    };

    // This is set to true when we're building a system package. For now
    // this is trivially detected using the "system_package_mode" bool
    // but we may want to make this more sophisticated in the future.
    const system_package = b.graph.system_package_mode;

    // This specifies our target wasm runtime. For now only one semi-usable
    // one exists so this is hardcoded.
    const wasm_target: WasmTarget = .browser;

    // Determine whether GTK supports X11 and Wayland. This is always safe
    // to run even on non-Linux platforms because any failures result in
    // defaults.
    const gtk_targets = gtk.targets(b);

    // We use env vars throughout the build so we grab them immediately here.
    var env = try std.process.getEnvMap(b.allocator);
    errdefer env.deinit();

    var config: Config = .{
        .optimize = optimize,
        .target = target,
        .wasm_target = wasm_target,
        .env = env,
    };

    //---------------------------------------------------------------
    // Target-specific properties
    config.xcframework_target = b.option(
        XCFramework.Target,
        "xcframework-target",
        "The target for the xcframework.",
    ) orelse .universal;

    //---------------------------------------------------------------
    // Comptime Interfaces
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
        rendererpkg.Impl,
        "renderer",
        "The app runtime to use. Not all values supported on all platforms.",
    ) orelse rendererpkg.Impl.default(target.result, wasm_target);

    //---------------------------------------------------------------
    // Feature Flags

    config.flatpak = b.option(
        bool,
        "flatpak",
        "Build for Flatpak (integrates with Flatpak APIs). Only has an effect targeting Linux.",
    ) orelse false;

    config.sentry = b.option(
        bool,
        "sentry",
        "Build with Sentry crash reporting. Default for macOS is true, false for any other system.",
    ) orelse sentry: {
        switch (target.result.os.tag) {
            .macos, .ios => break :sentry true,

            // Note its false for linux because the crash reports on Linux
            // don't have much useful information.
            else => break :sentry false,
        }
    };

    config.wayland = b.option(
        bool,
        "gtk-wayland",
        "Enables linking against Wayland libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.wayland;

    config.x11 = b.option(
        bool,
        "gtk-x11",
        "Enables linking against X11 libraries when using the GTK rendering backend.",
    ) orelse gtk_targets.x11;

    //---------------------------------------------------------------
    // Ghostty Exe Properties

    const version_string = b.option(
        []const u8,
        "version-string",
        "A specific version string to use for the build. " ++
            "If not specified, git will be used. This must be a semantic version.",
    );

    config.version = if (version_string) |v|
        // If an explicit version is given, we always use it.
        try std.SemanticVersion.parse(v)
    else version: {
        // If no explicit version is given, we try to detect it from git.
        const vsn = GitVersion.detect(b) catch |err| switch (err) {
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

    //---------------------------------------------------------------
    // Binary Properties

    // On NixOS, the built binary from `zig build` needs to patch the rpath
    // into the built binary for it to be portable across the NixOS system
    // it was built for. We default this to true if we can detect we're in
    // a Nix shell and have LD_LIBRARY_PATH set.
    config.patch_rpath = b.option(
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

    config.emit_test_exe = b.option(
        bool,
        "emit-test-exe",
        "Build and install test executables with 'build'",
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
            config.emit_helpgen) break :emit_docs false;

        // We always emit docs in system package mode.
        if (system_package) break :emit_docs true;

        // We only default to true if we can find pandoc.
        const path = Command.expandPath(b.allocator, "pandoc") catch
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

    config.emit_webdata = b.option(
        bool,
        "emit-webdata",
        "Build the website data for the website.",
    ) orelse false;

    config.emit_xcframework = b.option(
        bool,
        "emit-xcframework",
        "Build and install the xcframework for the macOS library.",
    ) orelse builtin.target.os.tag.isDarwin() and
        target.result.os.tag == .macos and
        config.app_runtime == .none and
        (!config.emit_bench and
            !config.emit_test_exe and
            !config.emit_helpgen);

    config.emit_macos_app = b.option(
        bool,
        "emit-macos-app",
        "Build and install the macOS app bundle.",
    ) orelse config.emit_xcframework;

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
                    // If we're not on darwin we want to use whatever the
                    // default is via the system package mode
                    .default = if (target.result.os.tag.isDarwin()) false else null,
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

        // These are dynamic libraries we default to true, preferring
        // to use system packages over building and installing libs
        // as they require additional ldconfig of library paths or
        // patching the rpath of the program to discover the dynamic library
        // at runtime
        for (&[_][]const u8{"gtk4-layer-shell"}) |dep| {
            _ = b.systemIntegrationOption(dep, .{ .default = true });
        }
    }

    return config;
}

/// Configure the build options with our values.
pub fn addOptions(self: *const Config, step: *std.Build.Step.Options) !void {
    // We need to break these down individual because addOption doesn't
    // support all types.
    step.addOption(bool, "flatpak", self.flatpak);
    step.addOption(bool, "x11", self.x11);
    step.addOption(bool, "wayland", self.wayland);
    step.addOption(bool, "sentry", self.sentry);
    step.addOption(apprt.Runtime, "app_runtime", self.app_runtime);
    step.addOption(font.Backend, "font_backend", self.font_backend);
    step.addOption(rendererpkg.Impl, "renderer", self.renderer);
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
        "{}",
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
        .app_runtime = std.meta.stringToEnum(apprt.Runtime, @tagName(options.app_runtime)).?,
        .font_backend = std.meta.stringToEnum(font.Backend, @tagName(options.font_backend)).?,
        .renderer = std.meta.stringToEnum(rendererpkg.Impl, @tagName(options.renderer)).?,
        .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
        .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
        .wasm_shared = options.wasm_shared,
    };
}

/// Returns the minimum OS version for the given OS tag. This shouldn't
/// be used generally, it should only be used for Darwin-based OS currently.
pub fn osVersionMin(tag: std.Target.Os.Tag) ?std.Target.Query.OsVersion {
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
//
// This is used to workaround compilation issues on macOS.
// (see for example https://github.com/mitchellh/ghostty/issues/1640).
pub fn genericMacOSTarget(
    b: *std.Build,
    arch: ?std.Target.Cpu.Arch,
) std.Build.ResolvedTarget {
    return b.resolveTargetQuery(.{
        .cpu_arch = arch orelse builtin.target.cpu.arch,
        .os_tag = .macos,
        .os_version_min = osVersionMin(.macos),
    });
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
    bench_parser,
    bench_stream,
    bench_codepoint_width,
    bench_grapheme_break,
    bench_page_init,
};

/// The release channel for the build.
pub const ReleaseChannel = enum {
    /// Unstable builds on every commit.
    tip,

    /// Stable tagged releases.
    stable,
};
