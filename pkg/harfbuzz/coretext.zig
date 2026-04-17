const macos = @import("macos");
const std = @import("std");
const c = @import("c");
const Face = @import("face.zig").Face;
const Font = @import("font.zig").Font;
const Error = @import("errors.zig").Error;

// Use custom extern functions so that the proper CoreText structs are used
// without a ptrcast.
extern fn hb_coretext_font_create(ct_face: *macos.text.Font) ?*c.hb_font_t;

/// Creates an hb_font_t font object from the specified CTFontRef.
pub fn createFont(face: *macos.text.Font) Error!Font {
    const handle = hb_coretext_font_create(face) orelse return Error.HarfbuzzFailed;
    return Font{ .handle = handle };
}

test {
    if (!@hasDecl(c, "hb_coretext_font_create")) return error.SkipZigTest;

    const name = try macos.foundation.String.createWithBytes("Monaco", .utf8, false);
    defer name.release();
    const desc = try macos.text.FontDescriptor.createWithNameAndSize(name, 12);
    defer desc.release();
    const font = try macos.text.Font.createWithFontDescriptor(desc, 12);
    defer font.release();

    var hb_font = try createFont(font);
    defer hb_font.destroy();
}
