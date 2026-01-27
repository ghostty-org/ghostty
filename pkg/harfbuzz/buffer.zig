const std = @import("std");
const c = @import("c.zig").c;
const common = @import("common.zig");
const Error = @import("errors.zig").Error;
const Direction = common.Direction;
const Script = common.Script;
const Language = common.Language;

/// Buffers serve a dual role in HarfBuzz; before shaping, they hold the
/// input characters that are passed to hb_shape(), and after shaping they
/// hold the output glyphs.
pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    /// Creates a new hb_buffer_t with all properties to defaults.
    pub fn create() Error!Buffer {
        const handle = c.hb_buffer_create() orelse return Error.HarfbuzzFailed;
        return Buffer{ .handle = handle };
    }

    /// Deallocate the buffer . Decreases the reference count on buffer by one.
    /// If the result is zero, then buffer and all associated resources are
    /// freed. See hb_buffer_reference().
    pub fn destroy(self: *Buffer) void {
        c.hb_buffer_destroy(self.handle);
    }

    /// Resets the buffer to its initial status, as if it was just newly
    /// created with hb_buffer_create().
    pub fn reset(self: Buffer) void {
        c.hb_buffer_reset(self.handle);
    }

    /// Returns the number of items in the buffer.
    pub fn getLength(self: Buffer) u32 {
        return c.hb_buffer_get_length(self.handle);
    }

    /// Sets the type of buffer contents. Buffers are either empty, contain
    /// characters (before shaping), or contain glyphs (the result of shaping).
    pub fn setContentType(self: Buffer, ct: ContentType) void {
        c.hb_buffer_set_content_type(self.handle, @intFromEnum(ct));
    }

    /// Fetches the type of buffer contents. Buffers are either empty, contain
    /// characters (before shaping), or contain glyphs (the result of shaping).
    pub fn getContentType(self: Buffer) ContentType {
        return @enumFromInt(c.hb_buffer_get_content_type(self.handle));
    }

    /// Appends a character with the Unicode value of codepoint to buffer,
    /// and gives it the initial cluster value of cluster . Clusters can be
    /// any thing the client wants, they are usually used to refer to the
    /// index of the character in the input text stream and are output in
    /// hb_glyph_info_t.cluster field.
    ///
    /// This function does not check the validity of codepoint, it is up to
    /// the caller to ensure it is a valid Unicode code point.
    pub fn add(self: Buffer, cp: u32, cluster: u32) void {
        c.hb_buffer_add(self.handle, cp, cluster);
    }

    /// Appends characters from text array to buffer . The item_offset is the
    /// position of the first character from text that will be appended, and
    /// item_length is the number of character. When shaping part of a larger
    /// text (e.g. a run of text from a paragraph), instead of passing just
    /// the substring corresponding to the run, it is preferable to pass the
    /// whole paragraph and specify the run start and length as item_offset and
    /// item_length , respectively, to give HarfBuzz the full context to be
    /// able, for example, to do cross-run Arabic shaping or properly handle
    /// combining marks at stat of run.
    ///
    /// This function does not check the validity of text , it is up to the
    /// caller to ensure it contains a valid Unicode code points.
    pub fn addCodepoints(self: Buffer, text: []const u32) void {
        c.hb_buffer_add_codepoints(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    /// See hb_buffer_add_codepoints().
    ///
    /// Replaces invalid UTF-32 characters with the buffer replacement code
    /// point, see hb_buffer_set_replacement_codepoint().
    pub fn addUTF32(self: Buffer, text: []const u32) void {
        c.hb_buffer_add_utf32(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    /// See hb_buffer_add_codepoints().
    ///
    /// Replaces invalid UTF-16 characters with the buffer replacement code
    /// point, see hb_buffer_set_replacement_codepoint().
    pub fn addUTF16(self: Buffer, text: []const u16) void {
        c.hb_buffer_add_utf16(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    /// See hb_buffer_add_codepoints().
    ///
    /// Replaces invalid UTF-8 characters with the buffer replacement code
    /// point, see hb_buffer_set_replacement_codepoint().
    pub fn addUTF8(self: Buffer, text: []const u8) void {
        c.hb_buffer_add_utf8(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    /// Similar to hb_buffer_add_codepoints(), but allows only access to first
    /// 256 Unicode code points that can fit in 8-bit strings.
    pub fn addLatin1(self: Buffer, text: []const u8) void {
        c.hb_buffer_add_latin1(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    /// Set the text flow direction of the buffer. No shaping can happen
    /// without setting buffer direction, and it controls the visual direction
    /// for the output glyphs; for RTL direction the glyphs will be reversed.
    /// Many layout features depend on the proper setting of the direction,
    /// for example, reversing RTL text before shaping, then shaping with LTR
    /// direction is not the same as keeping the text in logical order and
    /// shaping with RTL direction.
    pub fn setDirection(self: Buffer, dir: Direction) void {
        c.hb_buffer_set_direction(self.handle, @intFromEnum(dir));
    }

    /// See hb_buffer_set_direction()
    pub fn getDirection(self: Buffer) Direction {
        return @enumFromInt(c.hb_buffer_get_direction(self.handle));
    }

    /// Sets the script of buffer to script.
    ///
    /// Script is crucial for choosing the proper shaping behaviour for
    /// scripts that require it (e.g. Arabic) and the which OpenType features
    /// defined in the font to be applied.
    ///
    /// You can pass one of the predefined hb_script_t values, or use
    /// hb_script_from_string() or hb_script_from_iso15924_tag() to get the
    /// corresponding script from an ISO 15924 script tag.
    pub fn setScript(self: Buffer, script: Script) void {
        c.hb_buffer_set_script(self.handle, @intFromEnum(script));
    }

    /// See hb_buffer_set_script()
    pub fn getScript(self: Buffer) Script {
        return @enumFromInt(c.hb_buffer_get_script(self.handle));
    }

    /// Sets the language of buffer to language .
    ///
    /// Languages are crucial for selecting which OpenType feature to apply to
    /// the buffer which can result in applying language-specific behaviour.
    /// Languages are orthogonal to the scripts, and though they are related,
    /// they are different concepts and should not be confused with each other.
    ///
    /// Use hb_language_from_string() to convert from BCP 47 language tags to
    /// hb_language_t.
    pub fn setLanguage(self: Buffer, language: Language) void {
        c.hb_buffer_set_language(self.handle, language.handle);
    }

    /// See hb_buffer_set_language()
    pub fn getLanguage(self: Buffer) Language {
        return Language{ .handle = c.hb_buffer_get_language(self.handle) };
    }

    /// Returns buffer glyph information array. Returned pointer is valid as
    /// long as buffer contents are not modified.
    pub fn getGlyphInfos(self: Buffer) []GlyphInfo {
        var length: u32 = 0;
        const ptr: [*c]GlyphInfo = @ptrCast(c.hb_buffer_get_glyph_infos(self.handle, &length));
        return ptr[0..length];
    }

    /// Returns buffer glyph position array. Returned pointer is valid as
    /// long as buffer contents are not modified.
    ///
    /// If buffer did not have positions before, the positions will be
    /// initialized to zeros, unless this function is called from within a
    /// buffer message callback (see hb_buffer_set_message_func()), in which
    /// case NULL is returned.
    pub fn getGlyphPositions(self: Buffer) ?[]GlyphPosition {
        var length: u32 = 0;

        if (c.hb_buffer_get_glyph_positions(self.handle, &length)) |positions| {
            const ptr: [*]GlyphPosition = @ptrCast(positions);
            return ptr[0..length];
        }

        return null;
    }

    /// Sets unset buffer segment properties based on buffer Unicode contents.
    /// If buffer is not empty, it must have content type
    /// HB_BUFFER_CONTENT_TYPE_UNICODE.
    ///
    /// If buffer script is not set (ie. is HB_SCRIPT_INVALID), it will be set
    /// to the Unicode script of the first character in the buffer that has a
    /// script other than HB_SCRIPT_COMMON, HB_SCRIPT_INHERITED, and
    /// HB_SCRIPT_UNKNOWN.
    ///
    /// Next, if buffer direction is not set (ie. is HB_DIRECTION_INVALID), it
    /// will be set to the natural horizontal direction of the buffer script as
    /// returned by hb_script_get_horizontal_direction(). If
    /// hb_script_get_horizontal_direction() returns HB_DIRECTION_INVALID,
    /// then HB_DIRECTION_LTR is used.
    ///
    /// Finally, if buffer language is not set (ie. is HB_LANGUAGE_INVALID), it
    /// will be set to the process's default language as returned by
    /// hb_language_get_default(). This may change in the future by taking
    /// buffer script into consideration when choosing a language. Note that
    /// hb_language_get_default() is NOT threadsafe the first time it is
    /// called. See documentation for that function for details.
    pub fn guessSegmentProperties(self: Buffer) void {
        c.hb_buffer_guess_segment_properties(self.handle);
    }

    /// Sets the cluster level of a buffer. The `ClusterLevel` dictates one
    /// aspect of how HarfBuzz will treat non-base characters during shaping.
    pub fn setClusterLevel(self: Buffer, level: ClusterLevel) void {
        c.hb_buffer_set_cluster_level(self.handle, @intFromEnum(level));
    }
};

/// The type of hb_buffer_t contents.
pub const ContentType = enum(u2) {
    /// Initial value for new buffer.
    invalid = c.HB_BUFFER_CONTENT_TYPE_INVALID,

    /// The buffer contains input characters (before shaping).
    unicode = c.HB_BUFFER_CONTENT_TYPE_UNICODE,

    /// The buffer contains output glyphs (after shaping).
    glyphs = c.HB_BUFFER_CONTENT_TYPE_GLYPHS,
};

/// Data type for holding HarfBuzz's clustering behavior options. The cluster
/// level dictates one aspect of how HarfBuzz will treat non-base characters
/// during shaping.
pub const ClusterLevel = enum(u2) {
    /// In `monotone_graphemes`, non-base characters are merged into the
    /// cluster of the base character that precedes them. There is also cluster
    /// merging every time the clusters will otherwise become non-monotone.
    /// This is the default cluster level.
    monotone_graphemes = c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES,

    /// In `monotone_characters`, non-base characters are initially assigned
    /// their own cluster values, which are not merged into preceding base
    /// clusters. This allows HarfBuzz to perform additional operations like
    /// reorder sequences of adjacent marks. The output is still monotone, but
    /// the cluster values are more granular.
    monotone_characters = c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS,

    /// In `characters`, non-base characters are assigned their own cluster
    /// values, which are not merged into preceding base clusters. Moreover,
    /// the cluster values are not merged into monotone order. This is the most
    /// granular cluster level, and it is useful for clients that need to know
    /// the exact cluster values of each character, but is harder to use for
    /// clients, since clusters might appear in any order.
    characters = c.HB_BUFFER_CLUSTER_LEVEL_CHARACTERS,

    /// In `graphemes`, non-base characters are merged into the cluster of the
    /// base character that precedes them. This is similar to the Unicode
    /// Grapheme Cluster algorithm, but it is not exactly the same. The output
    /// is not forced to be monotone. This is useful for clients that want to
    /// use HarfBuzz as a cheap implementation of the Unicode Grapheme Cluster
    /// algorithm.
    graphemes = c.HB_BUFFER_CLUSTER_LEVEL_GRAPHEMES,
};

/// The hb_glyph_info_t is the structure that holds information about the
/// glyphs and their relation to input text.
pub const GlyphInfo = extern struct {
    /// either a Unicode code point (before shaping) or a glyph index (after shaping).
    codepoint: u32,
    _mask: u32,

    /// the index of the character in the original text that corresponds to
    /// this hb_glyph_info_t, or whatever the client passes to hb_buffer_add().
    /// More than one hb_glyph_info_t can have the same cluster value, if they
    /// resulted from the same character (e.g. one to many glyph substitution),
    /// and when more than one character gets merged in the same glyph (e.g.
    /// many to one glyph substitution) the hb_glyph_info_t will have the
    /// smallest cluster value of them. By default some characters are merged
    /// into the same cluster (e.g. combining marks have the same cluster as
    /// their bases) even if they are separate glyphs, hb_buffer_set_cluster_level()
    /// allow selecting more fine-grained cluster handling.
    cluster: u32,
    _var1: u32,
    _var2: u32,
};

/// The hb_glyph_position_t is the structure that holds the positions of the
/// glyph in both horizontal and vertical directions. All positions in
/// hb_glyph_position_t are relative to the current point.
pub const GlyphPosition = extern struct {
    /// how much the line advances after drawing this glyph when setting text
    /// in horizontal direction.
    x_advance: i32,

    /// how much the line advances after drawing this glyph when setting text
    /// in vertical direction.
    y_advance: i32,

    /// how much the glyph moves on the X-axis before drawing it, this should
    /// not affect how much the line advances.
    x_offset: i32,

    /// how much the glyph moves on the Y-axis before drawing it, this should
    /// not affect how much the line advances.
    y_offset: i32,

    _var: u32,
};

test "create" {
    const testing = std.testing;

    var buffer = try Buffer.create();
    defer buffer.destroy();
    buffer.reset();

    // Content type
    buffer.setContentType(.unicode);
    try testing.expectEqual(ContentType.unicode, buffer.getContentType());

    // Try add functions
    buffer.add('🥹', 27);
    var utf32 = [_]u32{ 'A', 'B', 'C' };
    var utf16 = [_]u16{ 'A', 'B', 'C' };
    var utf8 = [_]u8{ 'A', 'B', 'C' };
    buffer.addCodepoints(&utf32);
    buffer.addUTF32(&utf32);
    buffer.addUTF16(&utf16);
    buffer.addUTF8(&utf8);
    buffer.addLatin1(&utf8);

    // Guess properties first
    buffer.guessSegmentProperties();

    // Try to set properties
    buffer.setDirection(.ltr);
    try testing.expectEqual(Direction.ltr, buffer.getDirection());

    buffer.setScript(.arabic);
    try testing.expectEqual(Script.arabic, buffer.getScript());

    buffer.setLanguage(Language.fromString("en"));
}
