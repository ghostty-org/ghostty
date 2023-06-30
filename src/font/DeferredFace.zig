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

/// The loaded face (once loaded).
face: ?Face = null,

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

    pub fn deinit(self: *Fontconfig) void {
        self.pattern.destroy();
        self.* = undefined;
    }
};

/// CoreText specific data. This is only present when building with CoreText.
pub const CoreText = struct {
    /// The initialized font
    font: *macos.text.Font,

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

/// Initialize a deferred face that is already pre-loaded. The deferred face
/// takes ownership over the loaded face, deinit will deinit the loaded face.
pub fn initLoaded(face: Face) DeferredFace {
    return .{ .face = face };
}

pub fn deinit(self: *DeferredFace) void {
    if (self.face) |*face| face.deinit();
    switch (options.backend) {
        .fontconfig_freetype => if (self.fc) |*fc| fc.deinit(),
        .coretext, .coretext_freetype => if (self.ct) |*ct| ct.deinit(),
        .freetype => {},
        .web_canvas => if (self.wc) |*wc| wc.deinit(),
    }
    self.* = undefined;
}

/// Returns true if the face has been loaded.
pub inline fn loaded(self: DeferredFace) bool {
    return self.face != null;
}

/// Returns the name of this face. The memory is always owned by the
/// face so it doesn't have to be freed.
pub fn name(self: DeferredFace) ![:0]const u8 {
    switch (options.backend) {
        .freetype => {},

        .fontconfig_freetype => if (self.fc) |fc|
            return (try fc.pattern.get(.fullname, 0)).string,

        .coretext, .coretext_freetype => if (self.ct) |ct| {
            const display_name = ct.font.copyDisplayName();
            return display_name.cstringPtr(.utf8) orelse unsupported: {
                // "NULL if the internal storage of theString does not allow
                // this to be returned efficiently." In this case, we need
                // to allocate. But we can't return an allocated string because
                // we don't have an allocator. Let's use the stack and log it.
                var buf: [1024]u8 = undefined;
                const buf_name = display_name.cstring(&buf, .utf8) orelse
                    "<not enough internal storage space>";

                log.info(
                    "CoreText font required too much space to copy, value = {s}",
                    .{buf_name},
                );
                break :unsupported "<CoreText internal storage limited, see logs>";
            };
        },

        .web_canvas => if (self.wc) |wc| return wc.font_str,
    }

    return "TODO: built-in font names";
}

/// Load the deferred font face. This does nothing if the face is loaded.
pub fn load(
    self: *DeferredFace,
    lib: Library,
    size: font.face.DesiredSize,
) !void {
    // No-op if we already loaded
    if (self.face != null) return;

    switch (options.backend) {
        .fontconfig_freetype => {
            try self.loadFontconfig(lib, size);
            return;
        },

        .coretext => {
            try self.loadCoreText(lib, size);
            return;
        },

        .coretext_freetype => {
            try self.loadCoreTextFreetype(lib, size);
            return;
        },

        .web_canvas => {
            try self.loadWebCanvas(size);
            return;
        },

        // Unreachable because we must be already loaded or have the
        // proper configuration for one of the other deferred mechanisms.
        .freetype => unreachable,
    }
}

fn loadFontconfig(
    self: *DeferredFace,
    lib: Library,
    size: font.face.DesiredSize,
) !void {
    assert(self.face == null);
    const fc = self.fc.?;

    // Filename and index for our face so we can load it
    const filename = (try fc.pattern.get(.file, 0)).string;
    const face_index = (try fc.pattern.get(.index, 0)).integer;

    self.face = try Face.initFile(lib, filename, face_index, size);
}

fn loadCoreText(
    self: *DeferredFace,
    lib: Library,
    size: font.face.DesiredSize,
) !void {
    _ = lib;
    assert(self.face == null);
    const ct = self.ct.?;
    self.face = try Face.initFontCopy(ct.font, size);
}

fn loadCoreTextFreetype(
    self: *DeferredFace,
    lib: Library,
    size: font.face.DesiredSize,
) !void {
    assert(self.face == null);
    const ct = self.ct.?;

    // Get the URL for the font so we can get the filepath
    const url = ct.font.copyAttribute(.url);
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

    // TODO: face index 0 is not correct long term and we should switch
    // to using CoreText for rendering, too.
    //std.log.warn("path={s}", .{path_slice});
    self.face = try Face.initFile(lib, buf[0..path_slice.len :0], 0, size);
}

fn loadWebCanvas(
    self: *DeferredFace,
    size: font.face.DesiredSize,
) !void {
    assert(self.face == null);
    const wc = self.wc.?;
    self.face = try Face.initNamed(wc.alloc, wc.font_str, size, wc.presentation);
}

/// Returns true if this face can satisfy the given codepoint and
/// presentation. If presentation is null, then it just checks if the
/// codepoint is present at all.
///
/// This should not require the face to be loaded IF we're using a
/// discovery mechanism (i.e. fontconfig). If no discovery is used,
/// the face is always expected to be loaded.
pub fn hasCodepoint(self: DeferredFace, cp: u32, p: ?Presentation) bool {
    // If we have the face, use the face.
    if (self.face) |face| {
        if (p) |desired| if (face.presentation != desired) return false;
        return face.glyphIndex(cp) != null;
    }

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

        .coretext, .coretext_freetype => {
            // If we are using coretext, we check the loaded CT font.
            if (self.ct) |ct| {
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
        var font_str = try alloc.dupeZ(u8, ptr[0..len]);
        errdefer alloc.free(font_str);

        var face: DeferredFace = .{
            .wc = .{
                .alloc = alloc,
                .font_str = font_str,
                .presentation = @enumFromInt(presentation),
            },
        };
        errdefer face.deinit();

        var result = try alloc.create(DeferredFace);
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

    export fn deferred_face_load(self: *DeferredFace, pts: u16) void {
        self.load(.{}, .{ .points = pts }) catch |err| {
            log.warn("error loading deferred face err={}", .{err});
            return;
        };
    }

    /// Caller should not free this, the face is owned by the deferred face.
    export fn deferred_face_face(self: *DeferredFace) ?*Face {
        assert(self.loaded());
        return &self.face.?;
    }
};

test "preloaded" {
    const testing = std.testing;
    const testFont = @import("test.zig").fontRegular;

    var lib = try Library.init();
    defer lib.deinit();

    var face = try Face.init(lib, testFont, .{ .points = 12 });
    errdefer face.deinit();

    var def = initLoaded(face);
    defer def.deinit();

    try testing.expect(def.hasCodepoint(' ', null));
}

test "fontconfig" {
    if (options.backend != .fontconfig_freetype) return error.SkipZigTest;

    const discovery = @import("main.zig").discovery;
    const testing = std.testing;

    // Load freetype
    var lib = try Library.init();
    defer lib.deinit();

    // Get a deferred face from fontconfig
    var def = def: {
        var fc = discovery.Fontconfig.init();
        var it = try fc.discover(.{ .family = "monospace", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(!def.loaded());

    // Verify we can get the name
    const n = try def.name();
    try testing.expect(n.len > 0);

    // Load it and verify it works
    try def.load(lib, .{ .points = 12 });
    try testing.expect(def.hasCodepoint(' ', null));
    try testing.expect(def.face.?.glyphIndex(' ') != null);
}

test "coretext" {
    if (options.backend != .coretext) return error.SkipZigTest;

    const discovery = @import("main.zig").discovery;
    const testing = std.testing;

    // Load freetype
    var lib = try Library.init();
    defer lib.deinit();

    // Get a deferred face from fontconfig
    var def = def: {
        var fc = discovery.CoreText.init();
        var it = try fc.discover(.{ .family = "Monaco", .size = 12 });
        defer it.deinit();
        break :def (try it.next()).?;
    };
    defer def.deinit();
    try testing.expect(!def.loaded());
    try testing.expect(def.hasCodepoint(' ', null));

    // Verify we can get the name
    const n = try def.name();
    try testing.expect(n.len > 0);

    // Load it and verify it works
    try def.load(lib, .{ .points = 12 });
    try testing.expect(def.hasCodepoint(' ', null));
    try testing.expect(def.face.?.glyphIndex(' ') != null);
}
