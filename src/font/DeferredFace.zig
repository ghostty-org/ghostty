//! A deferred face represents a single font face with all the information
//! necessary to load it, but defers loading the full face until it is
//! needed.
//!
//! This allows us to have many fallback fonts to look for glyphs, but
//! only load them if they're really needed.
const DeferredFace = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const fontconfig = @import("fontconfig");
const macos = @import("macos");
const font = @import("main.zig");
const options = @import("main.zig").options;
const Library = @import("main.zig").Library;
const Face = @import("main.zig").Face;
const Presentation = @import("main.zig").Presentation;

const log = std.log.scoped(.deferred_face);

/// Fontconfig
fc: if (options.backend == .fontconfig_freetype) ?Fontconfig else void =
    if (options.backend == .fontconfig_freetype) null else {},

/// CoreText
ct: if (font.Discover == font.discovery.CoreText) ?CoreText else void =
    if (font.Discover == font.discovery.CoreText) null else {},

/// Canvas
wc: if (options.backend == .web_canvas) ?WebCanvas else void =
    if (options.backend == .web_canvas) null else {},

/// Fontconfig specific data. This is only present if building with fontconfig.
pub const Fontconfig = struct {
    /// The pattern for this font. This must be the "render prepared" pattern.
    /// (i.e. call FcFontRenderPrepare).
    pattern: *fontconfig.Pattern,

    /// Charset and Langset are used for quick lookup if a codepoint and
    /// presentation style are supported. They can be derived from pattern
    /// but are cached since they're frequently used.
    charset: *const fontconfig.CharSet,
    langset: *const fontconfig.LangSet,

    /// Variations to apply to this font.
    variations: []const font.face.Variation,

    pub fn deinit(self: *Fontconfig) void {
        self.pattern.destroy();
        self.* = undefined;
    }
};

/// CoreText specific data. This is only present when building with CoreText.
pub const CoreText = struct {
    /// The initialized font
    font: *macos.text.Font,

    /// Variations to apply to this font. We apply the variations to the
    /// search descriptor but sometimes when the font collection is
    /// made the variation axes are reset so we have to reapply them.
    variations: []const font.face.Variation,

    pub fn deinit(self: *CoreText) void {
        self.font.release();
        self.* = undefined;
    }
};

/// WebCanvas specific data. This is only present when building with canvas.
pub const WebCanvas = struct {
    /// The allocator to use for fonts
    alloc: Allocator,

    /// The string to use for the "font" attribute for the canvas
    font_str: [:0]const u8,

    /// The presentation for this font.
    presentation: Presentation,

    pub fn deinit(self: *WebCanvas) void {
        self.alloc.free(self.font_str);
        self.* = undefined;
    }
};

pub fn deinit(self: *DeferredFace) void {
    switch (options.backend) {
        .fontconfig_freetype => if (self.fc) |*fc| fc.deinit(),
        .freetype => {},
        .web_canvas => if (self.wc) |*wc| wc.deinit(),
        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |*ct| ct.deinit(),
    }
    self.* = undefined;
}

/// Returns the family name of the font.
pub fn familyName(self: DeferredFace, buf: []u8) ![]const u8 {
    switch (options.backend) {
        .freetype => {},

        .fontconfig_freetype => if (self.fc) |fc|
            return (try fc.pattern.get(.family, 0)).string,

        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |ct| {
            const family_name = ct.font.copyAttribute(.family_name) orelse
                return "unknown";
            return family_name.cstringPtr(.utf8) orelse unsupported: {
                break :unsupported family_name.cstring(buf, .utf8) orelse
                    return error.OutOfMemory;
            };
        },

        .web_canvas => if (self.wc) |wc| return wc.font_str,
    }

    return "";
}

/// Returns the name of this face. The memory is always owned by the
/// face so it doesn't have to be freed.
pub fn name(self: DeferredFace, buf: []u8) ![]const u8 {
    switch (options.backend) {
        .freetype => {},

        .fontconfig_freetype => if (self.fc) |fc|
            return (try fc.pattern.get(.fullname, 0)).string,

        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => if (self.ct) |ct| {
            const display_name = ct.font.copyDisplayName();
            return display_name.cstringPtr(.utf8) orelse unsupported: {
                // "NULL if the internal storage of theString does not allow
                // this to be returned efficiently." In this case, we need
                // to allocate. But we can't return an allocated string because
                // we don't have an allocator. Let's use the stack and log it.
                break :unsupported display_name.cstring(buf, .utf8) orelse
                    return error.OutOfMemory;
            };
        },

        .web_canvas => if (self.wc) |wc| return wc.font_str,
    }

    return "";
}

/// Load the deferred font face. This does nothing if the face is loaded.
pub fn load(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    return switch (options.backend) {
        .fontconfig_freetype => try self.loadFontconfig(lib, opts),
        .coretext, .coretext_harfbuzz, .coretext_noshape => try self.loadCoreText(lib, opts),
        .coretext_freetype => try self.loadCoreTextFreetype(lib, opts),
        .web_canvas => try self.loadWebCanvas(opts),

        // Unreachable because we must be already loaded or have the
        // proper configuration for one of the other deferred mechanisms.
        .freetype => unreachable,
    };
}

fn loadFontconfig(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const fc = self.fc.?;

    // Filename and index for our face so we can load it
    const filename = (try fc.pattern.get(.file, 0)).string;
    const face_index = (try fc.pattern.get(.index, 0)).integer;

    var face = try Face.initFile(lib, filename, face_index, opts);
    errdefer face.deinit();
    try face.setVariations(fc.variations, opts);
    return face;
}

fn loadCoreText(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    _ = lib;
    const ct = self.ct.?;
    var face = try Face.initFontCopy(ct.font, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);
    return face;
}

fn loadCoreTextFreetype(
    self: *DeferredFace,
    lib: Library,
    opts: font.face.Options,
) !Face {
    const ct = self.ct.?;

    // Get the URL for the font so we can get the filepath
    const url = ct.font.copyAttribute(.url) orelse
        return error.FontHasNoFile;
    defer url.release();

    // Get the path from the URL
    const path = url.copyPath() orelse return error.FontHasNoFile;
    defer path.release();

    // URL decode the path
    const blank = try macos.foundation.String.createWithBytes("", .utf8, false);
    defer blank.release();
    const decoded = try macos.foundation.URL.createStringByReplacingPercentEscapes(
        path,
        blank,
    );
    defer decoded.release();

    // Decode into a c string. 1024 bytes should be enough for anybody.
    var buf: [1024]u8 = undefined;
    const path_slice = decoded.cstring(buf[0..1023], .utf8) orelse
        return error.FontPathCantDecode;

    // Freetype requires null-terminated. We always leave space at
    // the end for a zero so we set that up here.
    buf[path_slice.len] = 0;

    // Face index 0 is not always correct. We don't ship this configuration
    // in a release build. Users should use the pure CoreText builds.
    //std.log.warn("path={s}", .{path_slice});
    var face = try Face.initFile(lib, buf[0..path_slice.len :0], 0, opts);
    errdefer face.deinit();
    try face.setVariations(ct.variations, opts);

    return face;
}

fn loadWebCanvas(
    self: *DeferredFace,
    opts: font.face.Options,
) !Face {
    const wc = self.wc.?;
    return try .initNamed(wc.alloc, wc.font_str, opts, wc.presentation);
}

/// Returns true if this face can satisfy the given codepoint and
/// presentation. If presentation is null, then it just checks if the
/// codepoint is present at all.
///
/// This should not require the face to be loaded IF we're using a
/// discovery mechanism (i.e. fontconfig). If no discovery is used,
/// the face is always expected to be loaded.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    switch (options.backend) {
        .fontconfig_freetype => {
            // If we are using fontconfig, use the fontconfig metadata to
            // avoid loading the face.
            if (self.fc) |fc| {
                // Check if char exists
                if (!fc.charset.hasChar(cp)) return false;

                // If we have a presentation, check it matches
                if (p) |desired| {
                    const emoji_lang = "und-zsye";
                    const actual: Presentation = if (fc.langset.hasLang(emoji_lang))
                        .emoji
                    else
                        .text;

                    return desired == actual;
                }

                return true;
            }
        },

        .coretext,
        .coretext_freetype,
        .coretext_harfbuzz,
        .coretext_noshape,
        => {
            // If we are using coretext, we check the loaded CT font.
            if (self.ct) |ct| {
                // This presentation check isn't as detailed as isColorGlyph
                // because forced presentation modes are only used for emoji and
                // emoji should always have color glyphs set. This can be
                // more correct by using the isColorGlyph logic but I'd want
                // to find a font that actually requires this so we can write
                // a test for it before changing it.
                if (p) |desired_p| {
                    const traits = ct.font.getSymbolicTraits();
                    const actual_p: Presentation = if (traits.color_glyphs) .emoji else .text;
                    if (actual_p != desired_p) return false;
                }

                // Turn UTF-32 into UTF-16 for CT API
                var unichars: [2]u16 = undefined;
                const pair = macos.foundation.stringGetSurrogatePairForLongCharacter(cp, &unichars);
                const len: usize = if (pair) 2 else 1;

                // Get our glyphs
                var glyphs = [2]macos.graphics.Glyph{ 0, 0 };
                return ct.font.getGlyphsForCharacters(unichars[0..len], glyphs[0..len]);
            }
        },

        // Canvas always has the codepoint because we have no way of
        // really checking and we let the browser handle it.
        .web_canvas => if (self.wc) |wc| {
            // Fast-path if we have a specific presentation and we
            // don't match, then it is definitely not this face.
            if (p) |desired| if (wc.presentation != desired) return false;

            // Slow-path: we initialize the font, render it, and check
            // if it works and the presentation matches.
            var face = Face.initNamed(
                wc.alloc,
                wc.font_str,
                .{ .points = 12 },
                wc.presentation,
            ) catch |err| {
                log.warn("failed to init face for codepoint check " ++
                    "face={s} err={}", .{
                    wc.font_str,
                    err,
                });

                return false;
            };
            defer face.deinit();
            return face.glyphIndex(cp) != null;
        },

        .freetype => {},
    }

    // This is unreachable because discovery mechanisms terminate, and
    // if we're not using a discovery mechanism, the face MUST be loaded.
    unreachable;
}

/// The wasm-compatible API.
pub const Wasm = struct {
    const wasm = @import("../os/wasm.zig");
    const alloc = wasm.alloc;

    export fn deferred_face_new(ptr: [*]const u8, len: usize, presentation: u16) ?*DeferredFace {
        return deferred_face_new_(ptr, len, presentation) catch |err| {
            log.warn("error creating deferred face err={}", .{err});
            return null;
        };
    }

    fn deferred_face_new_(ptr: [*]const u8, len: usize, presentation: u16) !*DeferredFace {
        const font_str = try alloc.dupeZ(u8, ptr[0..len]);
        errdefer alloc.free(font_str);

        var face: DeferredFace = .{
            .wc = .{
                .alloc = alloc,
                .font_str = font_str,
                .presentation = @enumFromInt(presentation),
            },
        };
        errdefer face.deinit();

        const result = try alloc.create(DeferredFace);
        errdefer alloc.destroy(result);
        result.* = face;
        return result;
    }

    export fn deferred_face_free(ptr: ?*DeferredFace) void {
        if (ptr) |v| {
            v.deinit();
            alloc.destroy(v);
        }
    }

    export fn deferred_face_load(self: *DeferredFace, pts: f32) void {
        self.load(.{}, .{ .points = pts }) catch |err| {
            log.warn("error loading deferred face err={}", .{err});
            return;
        };
    }
};

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Load freetype
    var lib = try Library.init(alloc);
    defer lib.deinit();

    // Get a deferred face from fontconfig
    var def = def: {
        var fc = discovery.Fontconfig.init();
        var it = try fc.discover(alloc, .{ .family = "monospace", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();

    // Verify we can get the name
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);

    // Load it and verify it works
    var face = try def.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}

test "coretext" {
    if (options.backend != .coretext) return error.SkipZigTest;

    const discovery = @import("main.zig").discovery;
    const testing = std.testing;
    const alloc = testing.allocator;

    // Load freetype
    var lib = try Library.init(alloc);
    defer lib.deinit();

    // Get a deferred face from fontconfig
    var def = def: {
        var fc = discovery.CoreText.init();
        var it = try fc.discover(alloc, .{ .family = "Monaco", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(def.hasCodepoint(' ', null));

    // Verify we can get the name
    var buf: [1024]u8 = undefined;
    const n = try def.name(&buf);
    try testing.expect(n.len > 0);

    // Load it and verify it works
    var face = try def.load(lib, .{ .size = .{ .points = 12 } });
    defer face.deinit();
    try testing.expect(face.glyphIndex(' ') != null);
}
