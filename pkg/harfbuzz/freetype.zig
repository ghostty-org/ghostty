const freetype = @import("freetype");
const std = @import("std");
const c = @import("c.zig");
const Face = @import("face.zig").Face;
const Font = @import("font.zig").Font;
const Error = @import("errors.zig").Error;

// Use custom extern functions so that the proper freetype structs are used
// without a ptrcast. These are only needed when interacting with freetype
// C structs.
extern fn hb_ft_face_create_referenced(ft_face: freetype.c.FT_Face) ?*c.hb_face_t;
extern fn hb_ft_font_create_referenced(ft_face: freetype.c.FT_Face) ?*c.hb_font_t;
extern fn hb_ft_font_get_face(font: ?*c.hb_font_t) freetype.c.FT_Face;

/// Creates an hb_face_t face object from the specified FT_Face.
///
/// This is the preferred variant of the hb_ft_face_create* function
/// family, because it calls FT_Reference_Face() on ft_face , ensuring
/// that ft_face remains alive as long as the resulting hb_face_t face
/// object remains alive. Also calls FT_Done_Face() when the hb_face_t
/// face object is destroyed.
///
/// Use this version unless you know you have good reasons not to.
pub fn createFace(face: freetype.c.FT_Face) Error!Face {
    const handle = hb_ft_face_create_referenced(face) orelse return Error.HarfbuzzFailed;
    return Face{ .handle = handle };
}

/// Creates an hb_font_t font object from the specified FT_Face.
pub fn createFont(face: freetype.c.FT_Face) Error!Font {
    const handle = hb_ft_font_create_referenced(face) orelse return Error.HarfbuzzFailed;
    return Font{ .handle = handle };
}

/// Configures the font-functions structure of the specified hb_font_t font
/// object to use FreeType font functions.
///
/// In particular, you can use this function to configure an existing
/// hb_face_t face object for use with FreeType font functions even if that
/// hb_face_t face object was initially created with hb_face_create(), and
/// therefore was not initially configured to use FreeType font functions.
///
/// An hb_face_t face object created with hb_ft_face_create() is preconfigured
/// for FreeType font functions and does not require this function to be used.
pub fn setFontFuncs(font: Font) void {
    c.hb_ft_font_set_funcs(font.handle);
}

test {
    if (!@hasDecl(c, "hb_ft_font_create_referenced")) return error.SkipZigTest;

    const testing = std.testing;
    const testFont = freetype.testing.font_regular;
    const ftc = freetype.c;
    const ftok = ftc.FT_Err_Ok;

    var ft_lib: ftc.FT_Library = undefined;
    if (ftc.FT_Init_FreeType(&ft_lib) != ftok)
        return error.FreeTypeInitFailed;
    defer _ = ftc.FT_Done_FreeType(ft_lib);

    var ft_face: ftc.FT_Face = undefined;
    try testing.expect(ftc.FT_New_Memory_Face(
        ft_lib,
        testFont,
        @intCast(testFont.len),
        0,
        &ft_face,
    ) == ftok);
    defer _ = ftc.FT_Done_Face(ft_face);

    var face = try createFace(ft_face);
    defer face.destroy();

    var font = try createFont(ft_face);
    defer font.destroy();
    setFontFuncs(font);
}
