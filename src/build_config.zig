//! Build options, available at comptime. Used to configure features. This
//! will reproduce some of the fields from builtin and build_options just
//! so we can limit the amount of imports we need AND give us the ability
//! to shim logic and values into them later.
const std = @import("std");
const builtin = @import("builtin");
const options = @import("build_options");
const assert = std.debug.assert;
const ApprtRuntime = @import("apprt/runtime.zig").Runtime;
const FontBackend = @import("font/backend.zig").Backend;
const RendererBackend = @import("renderer/backend.zig").Backend;
const BuildConfig = @import("build/Config.zig");

pub const ReleaseChannel = BuildConfig.ReleaseChannel;
pub const app_name = "winghostty";
pub const exe_name = "winghostty.exe";
pub const data_dir_name = "winghostty";
pub const legacy_data_dir_name = "ghostty";

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
const config = BuildConfig.fromOptions();
pub const exe_entrypoint = config.exe_entrypoint;
pub const app_runtime: ApprtRuntime = config.app_runtime;
pub const font_backend: FontBackend = config.font_backend;
pub const renderer: RendererBackend = config.renderer;
pub const i18n: bool = config.i18n;
pub const custom_shaders: bool = config.custom_shaders;

/// Stable application identifier used by the Windows-only fork for
/// instance naming and shared resource identity. It remains hardcoded
/// because many paths assume a compile-time constant.
pub const bundle_id = "io.github.amanthanvi.winghostty";

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
        if (builtin.target.cpu.arch.isWasm()) {
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

/// True if runtime safety checks are enabled.
pub const is_debug = switch (builtin.mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};
