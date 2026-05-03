const std = @import("std");

pub const Backend = enum {
    const WasmTarget = @import("../os/wasm/target.zig").Target;

    /// FreeType for font rendering with no font discovery enabled.
    freetype,

    /// FreeType for font rendering with a built-in Windows font directory
    /// scanner (C:\Windows\Fonts + %LOCALAPPDATA%\Microsoft\Windows\Fonts).
    /// Used when DirectWrite is not available; matches by family_name and
    /// SFNT name table without any external index.
    freetype_windows,

    /// Fontconfig for font discovery and FreeType for font rendering.
    fontconfig_freetype,

    /// CoreText for font discovery, rendering, and shaping (macOS).
    coretext,

    /// CoreText for font discovery, FreeType for rendering, and
    /// HarfBuzz for shaping (macOS).
    coretext_freetype,

    /// CoreText for font discovery and rendering, HarfBuzz for shaping
    coretext_harfbuzz,

    /// CoreText for font discovery and rendering, no shaping.
    coretext_noshape,

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
            // Avoid fontconfig on Windows because its libxml2 dependency
            // may not unpack due to symlinks. Use the FreeType-based
            // Windows font-directory scanner for discovery. A future
            // DirectWrite backend can replace this if needed.
            return .freetype_windows;
        }

        // macOS also supports "coretext_freetype" but there is no scenario
        // that is the default. It is only used by people who want to
        // self-compile Ghostty and prefer the freetype aesthetic.
        return if (target.os.tag.isDarwin()) .coretext else .fontconfig_freetype;
    }

    // All the functions below can be called at comptime or runtime to
    // determine if we have a certain dependency.

    pub fn hasFreetype(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .coretext_freetype,
            => true,

            .coretext,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }

    pub fn hasCoretext(self: Backend) bool {
        return switch (self) {
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            => true,

            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .web_canvas,
            => false,
        };
    }

    pub fn hasFontconfig(self: Backend) bool {
        return switch (self) {
            .fontconfig_freetype => true,

            .freetype,
            .freetype_windows,
            .coretext,
            .coretext_freetype,
            .coretext_harfbuzz,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }

    pub fn hasHarfbuzz(self: Backend) bool {
        return switch (self) {
            .freetype,
            .freetype_windows,
            .fontconfig_freetype,
            .coretext_freetype,
            .coretext_harfbuzz,
            => true,

            .coretext,
            .coretext_noshape,
            .web_canvas,
            => false,
        };
    }
};
