const std = @import("std");
const c = @import("c.zig");
const Error = @import("main.zig").Error;

pub const Weight = enum(c_uint) {
    thin = c.FC_WEIGHT_THIN,
    extralight = c.FC_WEIGHT_EXTRALIGHT,
    light = c.FC_WEIGHT_LIGHT,
    demilight = c.FC_WEIGHT_DEMILIGHT,
    book = c.FC_WEIGHT_BOOK,
    regular = c.FC_WEIGHT_REGULAR,
    medium = c.FC_WEIGHT_MEDIUM,
    demibold = c.FC_WEIGHT_DEMIBOLD,
    bold = c.FC_WEIGHT_BOLD,
    extrabold = c.FC_WEIGHT_EXTRABOLD,
    black = c.FC_WEIGHT_BLACK,
    extrablack = c.FC_WEIGHT_EXTRABLACK,
};

pub const Slant = enum(c_uint) {
    roman = c.FC_SLANT_ROMAN,
    italic = c.FC_SLANT_ITALIC,
    oblique = c.FC_SLANT_OBLIQUE,
};

pub const Property = enum {
    family,
    style,
    slant,
    weight,
    size,
    aspect,
    pixel_size,
    spacing,
    foundry,
    antialias,
    hinting,
    hint_style,
    vertical_layout,
    autohint,
    global_advance,
    width,
    file,
    index,
    ft_face,
    rasterizer,
    outline,
    scalable,
    color,
    variable,
    scale,
    symbol,
    dpi,
    rgba,
    minspace,
    source,
    charset,
    lang,
    fontversion,
    fullname,
    familylang,
    stylelang,
    fullnamelang,
    capability,
    embolden,
    embedded_bitmap,
    decorative,
    lcd_filter,
    font_features,
    font_variations,
    namelang,
    prgname,
    hash,
    postscript_name,
    font_has_hint,
    order,

    pub fn cval(self: Property) [:0]const u8 {
        @setEvalBranchQuota(10_000);
        inline for (@typeInfo(Property).Enum.fields) |field| {
            if (self == @field(Property, field.name)) {
                // Build our string in a comptime context so it is a binary
                // constant and not stack allocated.
                return comptime name: {
                    // Replace _ with ""
                    var buf: [field.name.len]u8 = undefined;
                    const count = std.mem.replace(u8, field.name, "_", "", &buf);
                    const replaced = buf[0 .. field.name.len - count];

                    // Build our string
                    var name: [replaced.len:0]u8 = undefined;
                    @memcpy(&name, replaced);
                    name[replaced.len] = 0;
                    break :name &name;
                };
            }
        }

        unreachable;
    }

    test "cval" {
        const testing = std.testing;
        try testing.expectEqualStrings("family", Property.family.cval());
        try testing.expectEqualStrings("pixelsize", Property.pixel_size.cval());
    }
};

pub const Result = enum(c_uint) {
    match = c.FcResultMatch,
    no_match = c.FcResultNoMatch,
    type_mismatch = c.FcResultTypeMismatch,
    no_id = c.FcResultNoId,
    out_of_memory = c.FcResultOutOfMemory,

    pub fn toError(self: Result) Error!void {
        return switch (self) {
            .match => {},
            .no_match => Error.FontconfigNoMatch,
            .type_mismatch => Error.FontconfigTypeMismatch,
            .no_id => Error.FontconfigNoId,
            .out_of_memory => Error.OutOfMemory,
        };
    }
};

pub const MatchKind = enum(c_uint) {
    pattern = c.FcMatchPattern,
    font = c.FcMatchFont,
    scan = c.FcMatchScan,
};
