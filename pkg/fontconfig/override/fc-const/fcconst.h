/* Copyright (C) 2025 fontconfig Authors */
/* SPDX-License-Identifier: HPND */

typedef struct _FcConstIndex {
    FcObject object;
    int      idx_obj;
    int      idx_variant;
} FcConstIndex;

typedef struct _FcConstSymbolMap {
    const FcChar8 *name;
    FcConstIndex   values[3];
} FcConstSymbolMap;

static const FcConstSymbolMap _FcBaseConstantSymbols[] = {
    {
        (const FcChar8 *) "antialias",
        {
            { FC_ANTIALIAS_OBJECT, 15, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "autohint",
        {
            { FC_AUTOHINT_OBJECT, 19, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "bgr",
        {
            { FC_RGBA_OBJECT, 27, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "black",
        {
            { FC_WEIGHT_OBJECT, 8, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "bold",
        {
            { FC_WEIGHT_OBJECT, 8, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "book",
        {
            { FC_WEIGHT_OBJECT, 8, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "charcell",
        {
            { FC_SPACING_OBJECT, 13, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "condensed",
        {
            { FC_WIDTH_OBJECT, 9, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "cursive",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "decorative",
        {
            { FC_DECORATIVE_OBJECT, 40, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "demibold",
        {
            { FC_WEIGHT_OBJECT, 8, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "demilight",
        {
            { FC_WEIGHT_OBJECT, 8, 4 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "dual",
        {
            { FC_SPACING_OBJECT, 13, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "embeddedbitmap",
        {
            { FC_EMBEDDED_BITMAP_OBJECT, 39, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "embolden",
        {
            { FC_EMBOLDEN_OBJECT, 38, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "emoji",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "expanded",
        {
            { FC_WIDTH_OBJECT, 9, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "extrablack",
        {
            { FC_WEIGHT_OBJECT, 8, 5 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "extrabold",
        {
            { FC_WEIGHT_OBJECT, 8, 6 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "extracondensed",
        {
            { FC_WIDTH_OBJECT, 9, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "extraexpanded",
        {
            { FC_WIDTH_OBJECT, 9, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "extralight",
        {
            { FC_WEIGHT_OBJECT, 8, 7 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "fangsong",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "fantasy",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "globaladvance",
        {
            { FC_GLOBAL_ADVANCE_OBJECT, 20, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "heavy",
        {
            { FC_WEIGHT_OBJECT, 8, 8 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "hintfull",
        {
            { FC_HINT_STYLE_OBJECT, 16, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "hinting",
        {
            { FC_HINTING_OBJECT, 17, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "hintmedium",
        {
            { FC_HINT_STYLE_OBJECT, 16, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "hintnone",
        {
            { FC_HINT_STYLE_OBJECT, 16, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "hintslight",
        {
            { FC_HINT_STYLE_OBJECT, 16, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "italic",
        {
            { FC_SLANT_OBJECT, 7, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "lcddefault",
        {
            { FC_LCD_FILTER_OBJECT, 41, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "lcdlegacy",
        {
            { FC_LCD_FILTER_OBJECT, 41, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "lcdlight",
        {
            { FC_LCD_FILTER_OBJECT, 41, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "lcdnone",
        {
            { FC_LCD_FILTER_OBJECT, 41, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "light",
        {
            { FC_WEIGHT_OBJECT, 8, 9 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "math",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 4 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "medium",
        {
            { FC_WEIGHT_OBJECT, 8, 10 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "minspace",
        {
            { FC_MINSPACE_OBJECT, 29, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "mono",
        {
            { FC_SPACING_OBJECT, 13, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "monospace",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 5 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "none",
        {
            { FC_RGBA_OBJECT, 27, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "normal",
        {
            { FC_WEIGHT_OBJECT, 8, 11 },
            { FC_WIDTH_OBJECT, 9, 4 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "oblique",
        {
            { FC_SLANT_OBJECT, 7, 1 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "outline",
        {
            { FC_OUTLINE_OBJECT, 24, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "proportional",
        {
            { FC_SPACING_OBJECT, 13, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "regular",
        {
            { FC_WEIGHT_OBJECT, 8, 12 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "rgb",
        {
            { FC_RGBA_OBJECT, 27, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "roman",
        {
            { FC_SLANT_OBJECT, 7, 2 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "sans-serif",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 6 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "scalable",
        {
            { FC_SCALABLE_OBJECT, 25, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "semibold",
        {
            { FC_WEIGHT_OBJECT, 8, 13 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "semicondensed",
        {
            { FC_WIDTH_OBJECT, 9, 5 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "semiexpanded",
        {
            { FC_WIDTH_OBJECT, 9, 6 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "semilight",
        {
            { FC_WEIGHT_OBJECT, 8, 14 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "serif",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 7 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "system-ui",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 8 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "thin",
        {
            { FC_WEIGHT_OBJECT, 8, 15 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ui-monospace",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 9 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ui-rounded",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 10 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ui-sans-serif",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 11 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ui-serif",
        {
            { FC_GENERIC_FAMILY_OBJECT, 56, 12 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ultrablack",
        {
            { FC_WEIGHT_OBJECT, 8, 16 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ultrabold",
        {
            { FC_WEIGHT_OBJECT, 8, 17 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ultracondensed",
        {
            { FC_WIDTH_OBJECT, 9, 7 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ultraexpanded",
        {
            { FC_WIDTH_OBJECT, 9, 8 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "ultralight",
        {
            { FC_WEIGHT_OBJECT, 8, 18 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "unknown",
        {
            { FC_RGBA_OBJECT, 27, 3 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "vbgr",
        {
            { FC_RGBA_OBJECT, 27, 4 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "verticallayout",
        {
            { FC_VERTICAL_LAYOUT_OBJECT, 18, 0 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
    {
        (const FcChar8 *) "vrgb",
        {
            { FC_RGBA_OBJECT, 27, 5 },
            { FC_INVALID_OBJECT, 0, 0 },
        },
    },
};

#define NUM_FC_CONST_SYMBOLS (sizeof (_FcBaseConstantSymbols) / sizeof (_FcBaseConstantSymbols[0]))

typedef struct _fcConstObjects {
    FcConstant values[20];
} FcConstantObjects;

static const FcConstantObjects _FcBaseConstantObjects[FC_MAX_BASE_OBJECT+1] = {
    {{{ NULL, NULL, 0 }}}    /* FC_INVALID_OBJECT */,
    {{{ NULL, NULL, 0 }}}    /* FC_FAMILY */,
    {{{ NULL, NULL, 0 }}}    /* FC_FAMILYLANG */,
    {{{ NULL, NULL, 0 }}}    /* FC_STYLE */,
    {{{ NULL, NULL, 0 }}}    /* FC_STYLELANG */,
    {{{ NULL, NULL, 0 }}}    /* FC_FULLNAME */,
    {{{ NULL, NULL, 0 }}}    /* FC_FULLNAMELANG */,
    {{
        { (const FcChar8 *) "italic", FC_SLANT, FC_SLANT_ITALIC},
        { (const FcChar8 *) "oblique", FC_SLANT, FC_SLANT_OBLIQUE},
        { (const FcChar8 *) "roman", FC_SLANT, FC_SLANT_ROMAN},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "black", FC_WEIGHT, FC_WEIGHT_BLACK},
        { (const FcChar8 *) "bold", FC_WEIGHT, FC_WEIGHT_BOLD},
        { (const FcChar8 *) "book", FC_WEIGHT, FC_WEIGHT_BOOK},
        { (const FcChar8 *) "demibold", FC_WEIGHT, FC_WEIGHT_DEMIBOLD},
        { (const FcChar8 *) "demilight", FC_WEIGHT, FC_WEIGHT_DEMILIGHT},
        { (const FcChar8 *) "extrablack", FC_WEIGHT, FC_WEIGHT_EXTRABLACK},
        { (const FcChar8 *) "extrabold", FC_WEIGHT, FC_WEIGHT_EXTRABOLD},
        { (const FcChar8 *) "extralight", FC_WEIGHT, FC_WEIGHT_EXTRALIGHT},
        { (const FcChar8 *) "heavy", FC_WEIGHT, FC_WEIGHT_HEAVY},
        { (const FcChar8 *) "light", FC_WEIGHT, FC_WEIGHT_LIGHT},
        { (const FcChar8 *) "medium", FC_WEIGHT, FC_WEIGHT_MEDIUM},
        { (const FcChar8 *) "normal", FC_WEIGHT, FC_WEIGHT_NORMAL},
        { (const FcChar8 *) "regular", FC_WEIGHT, FC_WEIGHT_REGULAR},
        { (const FcChar8 *) "semibold", FC_WEIGHT, FC_WEIGHT_DEMIBOLD},
        { (const FcChar8 *) "semilight", FC_WEIGHT, FC_WEIGHT_DEMILIGHT},
        { (const FcChar8 *) "thin", FC_WEIGHT, FC_WEIGHT_THIN},
        { (const FcChar8 *) "ultrablack", FC_WEIGHT, FC_WEIGHT_ULTRABLACK},
        { (const FcChar8 *) "ultrabold", FC_WEIGHT, FC_WEIGHT_EXTRABOLD},
        { (const FcChar8 *) "ultralight", FC_WEIGHT, FC_WEIGHT_EXTRALIGHT},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "condensed", FC_WIDTH, FC_WIDTH_CONDENSED},
        { (const FcChar8 *) "expanded", FC_WIDTH, FC_WIDTH_EXPANDED},
        { (const FcChar8 *) "extracondensed", FC_WIDTH, FC_WIDTH_EXTRACONDENSED},
        { (const FcChar8 *) "extraexpanded", FC_WIDTH, FC_WIDTH_EXTRAEXPANDED},
        { (const FcChar8 *) "normal", FC_WIDTH, FC_WIDTH_NORMAL},
        { (const FcChar8 *) "semicondensed", FC_WIDTH, FC_WIDTH_SEMICONDENSED},
        { (const FcChar8 *) "semiexpanded", FC_WIDTH, FC_WIDTH_SEMIEXPANDED},
        { (const FcChar8 *) "ultracondensed", FC_WIDTH, FC_WIDTH_ULTRACONDENSED},
        { (const FcChar8 *) "ultraexpanded", FC_WIDTH, FC_WIDTH_ULTRAEXPANDED},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_SIZE */,
    {{{ NULL, NULL, 0 }}}    /* FC_ASPECT */,
    {{{ NULL, NULL, 0 }}}    /* FC_PIXEL_SIZE */,
    {{
        { (const FcChar8 *) "charcell", FC_SPACING, FC_SPACING_CHARCELL},
        { (const FcChar8 *) "dual", FC_SPACING, FC_SPACING_DUAL},
        { (const FcChar8 *) "mono", FC_SPACING, FC_SPACING_MONO},
        { (const FcChar8 *) "proportional", FC_SPACING, FC_SPACING_PROPORTIONAL},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_FOUNDRY */,
    {{
        { (const FcChar8 *) "antialias", FC_ANTIALIAS, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "hintfull", FC_HINT_STYLE, FC_HINT_FULL},
        { (const FcChar8 *) "hintmedium", FC_HINT_STYLE, FC_HINT_MEDIUM},
        { (const FcChar8 *) "hintnone", FC_HINT_STYLE, FC_HINT_NONE},
        { (const FcChar8 *) "hintslight", FC_HINT_STYLE, FC_HINT_SLIGHT},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "hinting", FC_HINTING, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "verticallayout", FC_VERTICAL_LAYOUT, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "autohint", FC_AUTOHINT, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "globaladvance", FC_GLOBAL_ADVANCE, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_FILE */,
    {{{ NULL, NULL, 0 }}}    /* FC_INDEX */,
    {{{ NULL, NULL, 0 }}}    /* FC_RASTERIZER */,
    {{
        { (const FcChar8 *) "outline", FC_OUTLINE, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "scalable", FC_SCALABLE, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_DPI */,
    {{
        { (const FcChar8 *) "bgr", FC_RGBA, FC_RGBA_BGR},
        { (const FcChar8 *) "none", FC_RGBA, FC_RGBA_NONE},
        { (const FcChar8 *) "rgb", FC_RGBA, FC_RGBA_RGB},
        { (const FcChar8 *) "unknown", FC_RGBA, FC_RGBA_UNKNOWN},
        { (const FcChar8 *) "vbgr", FC_RGBA, FC_RGBA_VBGR},
        { (const FcChar8 *) "vrgb", FC_RGBA, FC_RGBA_VRGB},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_SCALE */,
    {{
        { (const FcChar8 *) "minspace", FC_MINSPACE, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_CHARWIDTH */,
    {{{ NULL, NULL, 0 }}}    /* FC_CHAR_HEIGHT */,
    {{{ NULL, NULL, 0 }}}    /* FC_MATRIX */,
    {{{ NULL, NULL, 0 }}}    /* FC_CHARSET */,
    {{{ NULL, NULL, 0 }}}    /* FC_LANG */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONTVERSION */,
    {{{ NULL, NULL, 0 }}}    /* FC_CAPABILITY */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONTFORMAT */,
    {{
        { (const FcChar8 *) "embolden", FC_EMBOLDEN, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "embeddedbitmap", FC_EMBEDDED_BITMAP, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "decorative", FC_DECORATIVE, FcTrue},
        { NULL, NULL, 0 },
    }},
    {{
        { (const FcChar8 *) "lcddefault", FC_LCD_FILTER, FC_LCD_DEFAULT},
        { (const FcChar8 *) "lcdlegacy", FC_LCD_FILTER, FC_LCD_LEGACY},
        { (const FcChar8 *) "lcdlight", FC_LCD_FILTER, FC_LCD_LIGHT},
        { (const FcChar8 *) "lcdnone", FC_LCD_FILTER, FC_LCD_NONE},
        { NULL, NULL, 0 },
    }},
    {{{ NULL, NULL, 0 }}}    /* FC_NAMELANG */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONT_FEATURES */,
    {{{ NULL, NULL, 0 }}}    /* FC_PRGNAME */,
    {{{ NULL, NULL, 0 }}}    /* FC_HASH */,
    {{{ NULL, NULL, 0 }}}    /* FC_POSTSCRIPT_NAME */,
    {{{ NULL, NULL, 0 }}}    /* FC_COLOR */,
    {{{ NULL, NULL, 0 }}}    /* FC_SYMBOL */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONT_VARIATIONS */,
    {{{ NULL, NULL, 0 }}}    /* FC_VARIABLE */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONT_HAS_HINT */,
    {{{ NULL, NULL, 0 }}}    /* FC_ORDER */,
    {{{ NULL, NULL, 0 }}}    /* FC_DESKTOP_NAME */,
    {{{ NULL, NULL, 0 }}}    /* FC_NAMED_INSTANCE */,
    {{{ NULL, NULL, 0 }}}    /* FC_FONT_WRAPPER */,
    {{
        { (const FcChar8 *) "cursive", FC_GENERIC_FAMILY, FC_FAMILY_CURSIVE},
        { (const FcChar8 *) "emoji", FC_GENERIC_FAMILY, FC_FAMILY_EMOJI},
        { (const FcChar8 *) "fangsong", FC_GENERIC_FAMILY, FC_FAMILY_FANGSONG},
        { (const FcChar8 *) "fantasy", FC_GENERIC_FAMILY, FC_FAMILY_FANTASY},
        { (const FcChar8 *) "math", FC_GENERIC_FAMILY, FC_FAMILY_MATH},
        { (const FcChar8 *) "monospace", FC_GENERIC_FAMILY, FC_FAMILY_MONO},
        { (const FcChar8 *) "sans-serif", FC_GENERIC_FAMILY, FC_FAMILY_SANS},
        { (const FcChar8 *) "serif", FC_GENERIC_FAMILY, FC_FAMILY_SERIF},
        { (const FcChar8 *) "system-ui", FC_GENERIC_FAMILY, FC_FAMILY_SYSTEM_UI},
        { (const FcChar8 *) "ui-monospace", FC_GENERIC_FAMILY, FC_FAMILY_UI_MONO},
        { (const FcChar8 *) "ui-rounded", FC_GENERIC_FAMILY, FC_FAMILY_UI_ROUNDED},
        { (const FcChar8 *) "ui-sans-serif", FC_GENERIC_FAMILY, FC_FAMILY_UI_SANS},
        { (const FcChar8 *) "ui-serif", FC_GENERIC_FAMILY, FC_FAMILY_UI_SERIF},
        { NULL, NULL, 0 },
    }},
};

#define NUM_FC_CONST_OBJS (sizeof (_FcBaseConstantObjects) / sizeof (_FcBaseConstantObjects[0]))
