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

/// The build configuratin options. This may not be all available options
/// to `zig build` but it contains all the options that the Ghostty source
/// needs to know about at comptime.
///
/// We put this all in a single struct so that we can check compatibility
/// between options, make it easy to copy and mutate options for different
/// build types, etc.
pub const BuildConfig = struct {
    version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 },
    static: bool = false,
    flatpak: bool = false,
    libadwaita: bool = false,
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
        step.addOption(bool, "libadwaita", self.libadwaita);
        step.addOption(apprt.Runtime, "app_runtime", self.app_runtime);
        step.addOption(font.Backend, "font_backend", self.font_backend);
        step.addOption(rendererpkg.Impl, "renderer", self.renderer);
        step.addOption(ExeEntrypoint, "exe_entrypoint", self.exe_entrypoint);
        step.addOption(WasmTarget, "wasm_target", self.wasm_target);
        step.addOption(bool, "wasm_shared", self.wasm_shared);

        // Our version. We also add the string version so we don't need
        // to do any allocations at runtime. This has to be long enough to
        // accomodate realistic large branch names for dev versions.
        var buf: [1024]u8 = undefined;
        step.addOption(std.SemanticVersion, "app_version", self.version);
        step.addOption([:0]const u8, "app_version_string", try std.fmt.bufPrintZ(
            &buf,
            "{}",
            .{self.version},
        ));
    }

    /// Rehydrate our BuildConfig from the comptime options. Note that not all
    /// options are available at comptime, so look closely at this implementation
    /// to see what is and isn't available.
    pub fn fromOptions() BuildConfig {
        return .{
            .version = options.app_version,
            .flatpak = options.flatpak,
            .libadwaita = options.libadwaita,
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
    bench_parser,
    bench_stream,
    bench_codepoint_width,
    bench_grapheme_break,
    bench_page_init,
    bench_screen_copy,
    bench_vt_insert_lines,
};
