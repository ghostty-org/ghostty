const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("c.zig").c;
const errors = @import("errors.zig");
const Library = @import("Library.zig");
const Tag = @import("tag.zig").Tag;
const Error = errors.Error;
const intToError = errors.intToError;

pub const Face = struct {
    handle: c.FT_Face,

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    /// Increment the counter of the face.
    pub fn ref(self: Face) void {
        _ = c.FT_Reference_Face(self.handle);
    }

    /// A macro that returns true whenever a face object contains some
    /// embedded bitmaps. See the available_sizes field of the FT_FaceRec structure.
    pub fn hasFixedSizes(self: Face) bool {
        return c.FT_HAS_FIXED_SIZES(self.handle);
    }

    /// A macro that returns true whenever a face object contains tables for
    /// color glyphs.
    pub fn hasColor(self: Face) bool {
        return c.FT_HAS_COLOR(self.handle);
    }

    /// A macro that returns true whenever a face object contains an ‘sbix’
    /// OpenType table and outline glyphs.
    pub fn hasSBIX(self: Face) bool {
        return c.FT_HAS_SBIX(self.handle);
    }

    /// A macro that returns true whenever a face object contains some
    /// multiple masters.
    pub fn hasMultipleMasters(self: Face) bool {
        return c.FT_HAS_MULTIPLE_MASTERS(self.handle);
    }

    /// A macro that returns true whenever a face object contains a scalable
    /// font face (true for TrueType, Type 1, Type 42, CID, OpenType/CFF,
    /// and PFR font formats).
    pub fn isScalable(self: Face) bool {
        return c.FT_IS_SCALABLE(self.handle);
    }

    /// Select a given charmap by its encoding tag (as listed in freetype.h).
    pub fn selectCharmap(self: Face, encoding: Encoding) Error!void {
        return intToError(c.FT_Select_Charmap(self.handle, @intFromEnum(encoding)));
    }

    /// Call FT_Request_Size to request the nominal size (in points).
    pub fn setCharSize(
        self: Face,
        char_width: i32,
        char_height: i32,
        horz_resolution: u16,
        vert_resolution: u16,
    ) Error!void {
        return intToError(c.FT_Set_Char_Size(
            self.handle,
            char_width,
            char_height,
            horz_resolution,
            vert_resolution,
        ));
    }

    /// Select a bitmap strike. To be more precise, this function sets the
    /// scaling factors of the active FT_Size object in a face so that bitmaps
    /// from this particular strike are taken by FT_Load_Glyph and friends.
    pub fn selectSize(self: Face, idx: i32) Error!void {
        return intToError(c.FT_Select_Size(self.handle, idx));
    }

    /// Return the glyph index of a given character code. This function uses
    /// the currently selected charmap to do the mapping.
    pub fn getCharIndex(self: Face, char: u32) ?u32 {
        const i = c.FT_Get_Char_Index(self.handle, char);
        return if (i == 0) null else i;
    }

    /// Load a glyph into the glyph slot of a face object.
    pub fn loadGlyph(self: Face, glyph_index: u32, load_flags: LoadFlags) Error!void {
        return intToError(c.FT_Load_Glyph(
            self.handle,
            glyph_index,
            @bitCast(load_flags),
        ));
    }

    /// Convert a given glyph image to a bitmap.
    pub fn renderGlyph(self: Face, render_mode: RenderMode) Error!void {
        return intToError(c.FT_Render_Glyph(
            self.handle.*.glyph,
            @intFromEnum(render_mode),
        ));
    }

    /// Return a pointer to a given SFNT table stored within a face.
    pub fn getSfntTable(self: Face, comptime tag: SfntTag) ?*tag.DataType() {
        return @ptrCast(@alignCast(c.FT_Get_Sfnt_Table(
            self.handle,
            @intFromEnum(tag),
        )));
    }

    /// Retrieve the number of name strings in the SFNT ‘name’ table.
    pub fn getSfntNameCount(self: Face) usize {
        return @intCast(c.FT_Get_Sfnt_Name_Count(self.handle));
    }

    /// Retrieve a string of the SFNT ‘name’ table for a given index.
    pub fn getSfntName(self: Face, i: usize) Error!c.FT_SfntName {
        var name: c.FT_SfntName = undefined;
        const res = c.FT_Get_Sfnt_Name(self.handle, @intCast(i), &name);
        return if (intToError(res)) |_| name else |err| err;
    }

    /// Load any SFNT font table into client memory.
    pub fn loadSfntTable(
        self: Face,
        alloc: Allocator,
        tag: Tag,
    ) (Allocator.Error || Error)!?[]u8 {
        const tag_c: c_ulong = @intCast(@as(u32, @bitCast(tag)));

        // Get the length of the table in bytes
        var len: c_ulong = 0;
        var res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, null, &len);
        _ = intToError(res) catch |err| return err;

        // If our length is zero we don't have a table.
        if (len == 0) return null;

        // Allocate a buffer to hold the table and load it
        const buf = try alloc.alloc(u8, len);
        errdefer alloc.free(buf);
        res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, buf.ptr, &len);
        _ = intToError(res) catch |err| return err;

        return buf;
    }

    /// Check whether a given SFNT table is available in a face.
    pub fn hasSfntTable(self: Face, tag: Tag) bool {
        const tag_c: c_ulong = @intCast(@as(u32, @bitCast(tag)));
        var len: c_ulong = 0;
        const res = c.FT_Load_Sfnt_Table(self.handle, tag_c, 0, null, &len);
        _ = intToError(res) catch return false;
        return len != 0;
    }

    /// Retrieve the font variation descriptor for a font.
    pub fn getMMVar(self: Face) Error!*c.FT_MM_Var {
        var result: *c.FT_MM_Var = undefined;
        const res = c.FT_Get_MM_Var(self.handle, @ptrCast(&result));
        return if (intToError(res)) |_| result else |err| err;
    }

    /// Get the design coordinates of the currently selected interpolated font.
    pub fn getVarDesignCoordinates(self: Face, coords: []c.FT_Fixed) Error!void {
        const res = c.FT_Get_Var_Design_Coordinates(
            self.handle,
            @intCast(coords.len),
            coords.ptr,
        );
        return intToError(res);
    }

    /// Choose an interpolated font design through design coordinates.
    pub fn setVarDesignCoordinates(self: Face, coords: []c.FT_Fixed) Error!void {
        const res = c.FT_Set_Var_Design_Coordinates(
            self.handle,
            @intCast(coords.len),
            coords.ptr,
        );
        return intToError(res);
    }

    /// Set the transformation that is applied to glyph images when they are
    /// loaded into a glyph slot through FT_Load_Glyph.
    pub fn setTransform(
        self: Face,
        matrix: ?*const c.FT_Matrix,
        delta: ?*const c.FT_Vector,
    ) void {
        c.FT_Set_Transform(
            self.handle,
            @ptrCast(@constCast(matrix)),
            @ptrCast(@constCast(delta)),
        );
    }
};

/// An enumeration to specify indices of SFNT tables loaded and parsed by
/// FreeType during initialization of an SFNT font. Used in the
/// FT_Get_Sfnt_Table API function.
pub const SfntTag = enum(c_int) {
    head = c.FT_SFNT_HEAD,
    maxp = c.FT_SFNT_MAXP,
    os2 = c.FT_SFNT_OS2,
    hhea = c.FT_SFNT_HHEA,
    vhea = c.FT_SFNT_VHEA,
    post = c.FT_SFNT_POST,
    pclt = c.FT_SFNT_PCLT,

    /// The data type for a given sfnt tag.
    pub fn DataType(comptime self: SfntTag) type {
        return switch (self) {
            .os2 => c.TT_OS2,
            .head => c.TT_Header,
            .post => c.TT_Postscript,
            .hhea => c.TT_HoriHeader,
            else => unreachable, // As-needed...
        };
    }
};

/// An enumeration to specify character sets supported by charmaps. Used in the
/// FT_Select_Charmap API function.
pub const Encoding = enum(u31) {
    none = c.FT_ENCODING_NONE,
    ms_symbol = c.FT_ENCODING_MS_SYMBOL,
    unicode = c.FT_ENCODING_UNICODE,
    sjis = c.FT_ENCODING_SJIS,
    prc = c.FT_ENCODING_PRC,
    big5 = c.FT_ENCODING_BIG5,
    wansung = c.FT_ENCODING_WANSUNG,
    johab = c.FT_ENCODING_JOHAB,
    adobe_standard = c.FT_ENCODING_ADOBE_STANDARD,
    adobe_expert = c.FT_ENCODING_ADOBE_EXPERT,
    adobe_custom = c.FT_ENCODING_ADOBE_CUSTOM,
    adobe_latin_1 = c.FT_ENCODING_ADOBE_LATIN_1,
    old_latin_2 = c.FT_ENCODING_OLD_LATIN_2,
    apple_roman = c.FT_ENCODING_APPLE_ROMAN,
};

/// https://freetype.org/freetype2/docs/reference/ft2-glyph_retrieval.html#ft_render_mode
pub const RenderMode = enum(c_uint) {
    normal = c.FT_RENDER_MODE_NORMAL,
    light = c.FT_RENDER_MODE_LIGHT,
    mono = c.FT_RENDER_MODE_MONO,
    lcd = c.FT_RENDER_MODE_LCD,
    lcd_v = c.FT_RENDER_MODE_LCD_V,
    sdf = c.FT_RENDER_MODE_SDF,
};

/// A collection of flags for FT_Load_Glyph that indicate
/// what kind of operations to perform during glyph loading.
///
/// Some of these flags are not included in the official FreeType
/// documentation, but are nevertheless present and named in the
/// header, so the names have been copied from there.
pub const LoadFlags = packed struct(c_int) {
    no_scale: bool = false,
    no_hinting: bool = false,
    render: bool = false,
    no_bitmap: bool = false,
    vertical_layout: bool = false,
    force_autohint: bool = false,
    crop_bitmap: bool = false,
    pedantic: bool = false,
    advance_only: bool = false,
    ignore_global_advance_width: bool = false,
    no_recurse: bool = false,
    ignore_transform: bool = false,
    monochrome: bool = false,
    linear_design: bool = false,
    sbits_only: bool = false,
    no_autohint: bool = false,
    target: Target = .normal,
    color: bool = false,
    compute_metrics: bool = false,
    bitmap_metrics_only: bool = false,
    svg_only: bool = false,
    no_svg: bool = false,
    _padding: u7 = 0,

    pub const Target = enum(u4) {
        normal = 0,
        light = 1,
        mono = 2,
        lcd = 3,
        lcd_v = 4,
    };

    test "bitcast" {
        const testing = std.testing;

        const cval: i32 = c.FT_LOAD_RENDER | c.FT_LOAD_PEDANTIC | c.FT_LOAD_COLOR;
        const flags = @as(LoadFlags, @bitCast(cval));
        try testing.expect(!flags.no_hinting);
        try testing.expect(flags.render);
        try testing.expect(flags.pedantic);
        try testing.expect(flags.color);

        // Verify bit alignment (for bit 9)
        const cval2: i32 = c.FT_LOAD_IGNORE_GLOBAL_ADVANCE_WIDTH;
        const flags2 = @as(LoadFlags, @bitCast(cval2));
        try testing.expect(flags2.ignore_global_advance_width);
        try testing.expect(!flags2.no_recurse);
    }

    test "all flags individually" {
        const testing = std.testing;

        try testing.expectEqual(
            c.FT_LOAD_DEFAULT,
            @as(c_int, @bitCast(LoadFlags{})),
        );

        inline for ([_]struct { c_int, []const u8 }{
            .{ c.FT_LOAD_NO_SCALE, "no_scale" },
            .{ c.FT_LOAD_NO_HINTING, "no_hinting" },
            .{ c.FT_LOAD_RENDER, "render" },
            .{ c.FT_LOAD_NO_BITMAP, "no_bitmap" },
            .{ c.FT_LOAD_VERTICAL_LAYOUT, "vertical_layout" },
            .{ c.FT_LOAD_FORCE_AUTOHINT, "force_autohint" },
            .{ c.FT_LOAD_CROP_BITMAP, "crop_bitmap" },
            .{ c.FT_LOAD_PEDANTIC, "pedantic" },
            .{ c.FT_LOAD_ADVANCE_ONLY, "advance_only" },
            .{ c.FT_LOAD_IGNORE_GLOBAL_ADVANCE_WIDTH, "ignore_global_advance_width" },
            .{ c.FT_LOAD_NO_RECURSE, "no_recurse" },
            .{ c.FT_LOAD_IGNORE_TRANSFORM, "ignore_transform" },
            .{ c.FT_LOAD_MONOCHROME, "monochrome" },
            .{ c.FT_LOAD_LINEAR_DESIGN, "linear_design" },
            .{ c.FT_LOAD_SBITS_ONLY, "sbits_only" },
            .{ c.FT_LOAD_NO_AUTOHINT, "no_autohint" },
            .{ c.FT_LOAD_COLOR, "color" },
            .{ c.FT_LOAD_COMPUTE_METRICS, "compute_metrics" },
            .{ c.FT_LOAD_BITMAP_METRICS_ONLY, "bitmap_metrics_only" },
            .{ c.FT_LOAD_SVG_ONLY, "svg_only" },
            .{ c.FT_LOAD_NO_SVG, "no_svg" },
        }) |pair| {
            var flags: LoadFlags = .{};
            @field(flags, pair[1]) = true;
            try testing.expectEqual(pair[0], @as(c_int, @bitCast(flags)));
        }
    }

    test "all load targets" {
        const testing = std.testing;

        inline for ([_]struct { c_int, Target }{
            .{ c.FT_LOAD_TARGET_NORMAL, .normal },
            .{ c.FT_LOAD_TARGET_LIGHT, .light },
            .{ c.FT_LOAD_TARGET_MONO, .mono },
            .{ c.FT_LOAD_TARGET_LCD, .lcd },
            .{ c.FT_LOAD_TARGET_LCD_V, .lcd_v },
        }) |pair| {
            const flags: LoadFlags = .{ .target = pair[1] };
            try testing.expectEqual(pair[0], @as(c_int, @bitCast(flags)));
        }
    }
};

test "loading memory font" {
    const testing = std.testing;
    const font_data = @import("test.zig").font_regular;

    var lib = try Library.init();
    defer lib.deinit();
    var face = try lib.initMemoryFace(font_data, 0);
    defer face.deinit();

    // Try APIs
    try face.selectCharmap(.unicode);
    try testing.expect(!face.hasFixedSizes());
    try face.setCharSize(12, 0, 0, 0);

    // Try loading
    const idx = face.getCharIndex('A').?;
    try face.loadGlyph(idx, .{});

    // Try getting a truetype table
    const os2 = face.getSfntTable(.os2);
    try testing.expect(os2 != null);
}
