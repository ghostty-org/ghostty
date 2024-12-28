//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const apprt = @import("apprt.zig");
const font = @import("font/main.zig");
const rendererpkg = @import("renderer.zig");
const WasmTarget = @import("os/wasm/target.zig").Target;

/// The build configurations options. This may not be all available options
/// to `zig build` but it contains all the options that the Ghostty source
/// needs to know about at comptime.
///
/// We put this all in a single struct so that we can check compatibility
/// between options, make it easy to copy and mutate options for different
/// build types, etc.
pub const BuildConfig = struct {
    version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    flatpak: bool = false,
    adwaita: bool = false,
    x11: bool = false,
    app_runtime: apprt.Runtime = .none,
    renderer: rendererpkg.Impl = .opengl,
    font_backend: font.Backend = .freetype,

    /// The entrypoint for exe targets.
    exe_entrypoint: ExeEntrypoint = .ghostty,

    /// The target runtime for the wasm build and whether to use wasm shared
    /// memory or not. These are both legacy wasm-specific options that we
    /// will probably have to revisit when we get back to work on wasm.
    wasm_target: WasmTarget = .browser,
    wasm_shared: bool = true,

    /// Configure the build options with our values.
    pub fn addOptions(self: BuildConfig, step: *std.Build.Step.Options) !void {
        // We need to break these down individual because addOption doesn't
        // support all types.
        step.addOption(bool, "flatpak", self.flatpak);
        step.addOption(bool, "adwaita", self.adwaita);
        step.addOption(bool, "x11", self.x11);
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

    /// Rehydrate our BuildConfig from the comptime options. Note that not all
    /// options are available at comptime, so look closely at this implementation
    /// to see what is and isn't available.
    pub fn fromOptions() BuildConfig {
        return .{
            .version = options.app_version,
            .flatpak = options.flatpak,
            .adwaita = options.adwaita,
            .app_runtime = std.meta.stringToEnum(apprt.Runtime, @tagName(options.app_runtime)).?,
            .font_backend = std.meta.stringToEnum(font.Backend, @tagName(options.font_backend)).?,
            .renderer = std.meta.stringToEnum(rendererpkg.Impl, @tagName(options.renderer)).?,
            .exe_entrypoint = std.meta.stringToEnum(ExeEntrypoint, @tagName(options.exe_entrypoint)).?,
            .wasm_target = std.meta.stringToEnum(WasmTarget, @tagName(options.wasm_target)).?,
            .wasm_shared = options.wasm_shared,
        };
    }
};

/// The semantic version of this build.
pub const version = options.app_version;
pub const version_string = options.app_version_string;

/// The release channel for this build.
pub const release_channel = std.meta.stringToEnum(ReleaseChannel, @tagName(options.release_channel)).?;

/// The optimization mode as a string.
pub const mode_string = mode: {
    const m = @tagName(builtin.mode);
    if (std.mem.lastIndexOfScalar(u8, m, '.')) |i| break :mode m[i..];
    break :mode m;
};

/// The artifact we're producing. This can be used to determine if we're
/// building a standalone exe, an embedded lib, etc.
pub const artifact = Artifact.detect();

/// Our build configuration. We re-export a lot of these back at the
/// top-level so its a bit cleaner to use throughout the code. See the doc
/// comments in BuildConfig for details on each.
pub const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const flatpak = options.flatpak;
pub const app_runtime: apprt.Runtime = config.app_runtime;
pub const font_backend: font.Backend = config.font_backend;
pub const renderer: rendererpkg.Impl = config.renderer;

/// The bundle ID for the app. This is used in many places and is currently
/// hardcoded here. We could make this configurable in the future if there
/// is a reason to do so.
///
/// On macOS, this must match the App bundle ID. We can get that dynamically
/// via an API but I don't want to pay the cost of that at runtime.
///
/// On GTK, this should match the various folders with resources.
///
/// There are many places that don't use this variable so simply swapping
/// this variable is NOT ENOUGH to change the bundle ID. I just wanted to
/// avoid it in Zig coe as much as possible.
pub const bundle_id = "com.mitchellh.ghostty";

/// True if we should have "slow" runtime safety checks. The initial motivation
/// for this was terminal page/pagelist integrity checks. These were VERY
/// slow but very thorough. But they made it so slow that the terminal couldn't
/// be used for real work. We'd love to have an option to run a build with
/// safety checks that could be used for real work. This lets us do that.
pub const slow_runtime_safety = std.debug.runtime_safety and switch (builtin.mode) {
    .Debug => true,
    .ReleaseSafe,
    .ReleaseSmall,
    .ReleaseFast,
    => false,
};

pub const Artifact = enum {
    /// Standalone executable
    exe,

    /// Embeddable library
    lib,

    /// The WASM-targeted module.
    wasm_module,

    pub fn detect() Artifact {
        if (builtin.target.isWasm()) {
            assert(builtin.output_mode == .Obj);
            assert(builtin.link_mode == .Static);
            return .wasm_module;
        }

        return switch (builtin.output_mode) {
            .Exe => .exe,
            .Lib => .lib,
            else => {
                @compileLog(builtin.output_mode);
                @compileError("unsupported artifact output mode");
            },
        };
    }
};

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
