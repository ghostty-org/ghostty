const std = @import("std");

pub const Backend = enum {
    const WasmTarget = @import("../os/wasm/target.zig").Target;

    /// FreeType for font rendering with no font discovery enabled.
    freetype,

    /// Native Windows font discovery with FreeType rendering.
    windows_freetype,

    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// Use the browser font system and the Canvas API (wasm). This limits
    /// the available fonts to browser fonts (anything Canvas natively
    /// supports).
    web_canvas,

    /// Returns the default backend for a build environment. This is
    /// meant to be called at comptime by the build.zig script. To get the
    /// backend look at build_options.
    pub fn default(
        target: std.Target,
        wasm_target: WasmTarget,
    ) Backend {
        if (target.cpu.arch == .wasm32) {
            return switch (wasm_target) {
                .browser => .web_canvas,
            };
        }

        if (target.os.tag == .windows) {
            return .windows_freetype;
        }

        return .fontconfig_freetype;
    }

    // All the functions below can be called at comptime or runtime to
    // determine if we have a certain dependency.

    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .freetype,
            .windows_freetype,
            .fontconfig_freetype,
            => true,

            .web_canvas,
            => false,
        };
    }

    pub fn hasCoretext(self: Backend) bool {
        _ = self;
        return false;
    }

    pub fn hasFontconfig(self: Backend) bool {
        return switch (self) {
            .fontconfig_freetype => true,

            .freetype,
            .windows_freetype,
            .web_canvas,
            => false,
        };
    }

    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .freetype,
            .windows_freetype,
            .fontconfig_freetype,
            => true,

            .web_canvas,
            => false,
        };
    }
};
