const std = @import("std");
const sfnt = @import("sfnt.zig");

/// Glyph Data Table
///
/// This takes a little bit of a different form than other tables that we
/// have parsers for. Due to the fact that this table contains arrays of
/// arbitrary length, we store a pointer (slice) to the underlying data,
/// and then have functions for getting and interpreting specific parts.
///
/// References:
/// - https://learn.microsoft.com/en-us/typography/opentype/spec/glyf
///
/// Field names are in camelCase to match names in spec.
pub const Glyf = struct {
    data: []const u8,

    /// https://learn.microsoft.com/en-us/typography/opentype/spec/glyf#table-organization
    pub const Entry = struct {
        header: Header,

        /// We store a reference to the original bytes so that we can
        /// validate or iterate the contours or components of the glyph.
        ///
        /// This data starts immediately after the header.
        data: []const u8,

        /// The header that's always present at
        /// the start of any glyph in the table.
        ///
        /// Depending on the number of contours, the data that
        /// comes afterwards must be interpreted differently.
        ///
        /// References:
        /// - https://learn.microsoft.com/en-us/typography/opentype/spec/glyf#glyph-headers
        pub const Header = extern struct {
            /// If the number of contours is greater than
            /// or equal to zero, this is a simple glyph.
            ///
            /// If negative, this is a composite glyph — the
            /// value -1 should be used for composite glyphs.
            numberOfContours: sfnt.int16 align(1),

            /// Minimum x for coordinate data.
            xMin: sfnt.int16 align(1),

            /// Minimum y for coordinate data.
            yMin: sfnt.int16 align(1),

            /// Maximum x for coordinate data.
            xMax: sfnt.int16 align(1),

            /// Maximum y for coordinate data.
            yMax: sfnt.int16 align(1),
        };

        /// The bit flags that describe the point data in simple glyph entries.
        ///
        /// Doc strings for each field are copied with minimal modification
        /// from the opentype spec. Field names are altered to be clearer and
        /// more succinct, and mentions of those field names in doc strings
        /// have been similarly modified to match the ones in the struct.
        ///
        /// The relationship between the <x|y>_short and <x|y>_repeat_or_sign
        /// fields is important, and poorly explained in prose, so instead of
        /// that, here's a table that should make it easier to understand.
        ///
        ///          x_short > | false            | true             |
        /// x_repeat_or_sign V |------------------|------------------|
        ///                    | The x-coordinate | The x-coordinate |
        ///              false | of this point is | of this point is |
        ///                    | a signed 16-bit  | an unsigned byte |
        ///                    | value added to   | value treated as |
        ///                    | the *Coordinates | negative, added  |
        ///                    | array.           | to the array of  |
        ///                    |                  | xCoordinates.    |
        /// -------------------|------------------|------------------|
        ///                    | The x-coordinate | The x-coordinate |
        ///               true | of this point is | of this point is |
        ///                    | the same as the  | an unsigned byte |
        ///                    | previous point;  | value treated as |
        ///                    | nothing added to | positive, added  |
        ///                    | the xCoordinates | to the array of  |
        ///                    | array.           | xCoordinates.    |
        /// -------------------|------------------|------------------|
        ///
        /// References:
        /// - https://learn.microsoft.com/en-us/typography/opentype/spec/glyf#simple-glyph-description
        pub const SimpleFlags = packed struct(u8) {
            /// If set, the point is on the curve; otherwise, it is off the curve.
            on_curve: bool,

            /// If set, the corresponding x-coordinate is 1 byte long,
            /// and the sign is determined by the x_repeat_or_sign flag.
            ///
            /// If not set, its interpretation depends on the x_repeat_or_sign
            /// flag: If that other flag is set, the x-coordinate is the same
            /// as the previous x-coordinate, and no element is added to the
            /// xCoordinates array. If both flags are not set, the corresponding
            /// element in the xCoordinates array is two bytes and interpreted
            /// as a signed integer.
            ///
            /// See the description of the x_repeat_or_sign flag for additional
            /// information.
            x_short: bool,

            /// If set, the corresponding y-coordinate is 1 byte long,
            /// and the sign is determined by the y_repeat_or_sign flag.
            ///
            /// If not set, its interpretation depends on the y_repeat_or_sign
            /// flag: If that other flag is set, the y-coordinate is the same
            /// as the previous y-coordinate, and no element is added to the
            /// yCoordinates array. If both flags are not set, the corresponding
            /// element in the yCoordinates array is two bytes and interpreted
            /// as a signed integer.
            ///
            /// See the description of the y_repeat_or_sign flag for additional
            /// information.
            y_short: bool,

            /// If set, the next byte (read as unsigned) specifies the number
            /// of additional times this flag byte is to be repeated in the
            /// logical flags array — that is, the number of additional logical
            /// flag entries inserted after this entry. (In the expanded logical
            /// array, this bit is ignored.) In this way, the number of flags
            /// listed can be smaller than the number of points in the glyph
            /// description.
            repeat: bool,

            /// This flag has two meanings, depending on how the x_short flag
            /// is set. If x_short is set, this bit describes the sign of the
            /// value, with 1 equaling positive and 0 negative. If x_short is
            /// not set and this bit is set, then the current x-coordinate is
            /// the same as the previous x-coordinate. If x_short is not set
            /// and this bit is also not set, the current x-coordinate is a
            /// signed 16-bit delta vector.
            x_repeat_or_sign: bool,

            /// This flag has two meanings, depending on how the y_short flag
            /// is set. If y_short is set, this bit describes the sign of the
            /// value, with 1 equaling positive and 0 negative. If y_short is
            /// not set and this bit is set, then the current y-coordinate is
            /// the same as the previous y-coordinate. If y_short is not set
            /// and this bit is also not set, the current y-coordinate is a
            /// signed 16-bit delta vector.
            y_repeat_or_sign: bool,

            /// If set, contours in the glyph description could overlap.
            ///
            /// Use of this flag is not required — that is, contours may
            /// overlap without having this flag set. When used, it must
            /// be set on the first flag byte for the glyph.
            overlap: bool,

            /// Bit 7 is reserved: set to zero.
            reserved: bool,

            /// Determine the size (in bytes) of the corresponding
            /// value in the `xCoordinates` array for this flagset.
            ///
            /// See doc comments on the struct for an explanation.
            pub inline fn xBytes(self: SimpleFlags) u2 {
                return if (self.x_short)
                    // short, 1 byte
                    1
                else if (self.x_repeat_or_sign)
                    // repeat, 0 bytes
                    0
                else
                    // otherwise, 16-bit, 2 bytes.
                    2;
            }

            /// Determine the size (in bytes) of the corresponding
            /// value in the `yCoordinates` array for this flagset.
            ///
            /// See doc comments on the struct for an explanation.
            pub inline fn yBytes(self: SimpleFlags) u2 {
                return if (self.y_short)
                    // short, 1 byte
                    1
                else if (self.y_repeat_or_sign)
                    // repeat, 0 bytes
                    0
                else
                    // otherwise, 16-bit, 2 bytes.
                    2;
            }
        };

        pub const Type = enum {
            /// A glyph made of standard contours.
            simple,
            /// A glyph made of references to other glyphs.
            composite,
        };

        /// Initialize an entry from the provided data.
        ///
        /// This DOES NOT COPY the data, it only stores a pointer to it.
        ///
        /// The lifetime of this struct, then, is the same as the
        /// lifetime of the data that is used to initialize it.
        pub fn init(data: []const u8) error{EndOfStream}!Entry {
            var fbs = std.io.fixedBufferStream(data);
            const reader = fbs.reader();
            const header = try reader.readStructEndian(Header, .big);
            return .{ .header = header, .data = data[fbs.pos..] };
        }

        /// Identifies what type (simple or composite) of entry this is.
        pub fn entryType(self: Entry) Type {
            return if (self.header.numberOfContours >= 0)
                .simple
            else
                .composite;
        }

        /// Errors that can be returned from `Entry.size()`.
        pub const SizeError = error{
            /// The entry's data wasn't large enough, ran
            /// out of bytes before we were done reading.
            EndOfStream,

            /// The entry contains hinting instructions,
            /// which we don't currently support.
            InstructionsNotSupported,

            /// The entry is a composite glyph,
            /// which we don't currently support.
            CompositeNotSupported,

            /// The elements of the end points array
            /// must strictly monotonically increase.
            ///
            /// This error means the provided entry violated that.
            EndPointsOutOfOrder,

            /// This entry defines points past the index determined
            /// by the final element of the endPtsOfContours array.
            TooManyPoints,
        };

        /// Determines the size (in bytes) of this entry.
        ///
        /// If the entry is valid, returns the number of bytes
        /// taken up by this entry, including its header.
        ///
        /// NOTE: Currently produces errors when given composite glyphs
        ///       or any glyphs that have hinting instructions included.
        pub fn size(self: Entry) SizeError!usize {
            var fbs = std.io.fixedBufferStream(self.data);
            const reader = fbs.reader();
            switch (self.entryType()) {
                // https://learn.microsoft.com/en-us/typography/opentype/spec/glyf#simple-glyph-description
                .simple => {
                    const num_contours: usize = @intCast(self.header.numberOfContours);

                    // From the spec:
                    //
                    // > If a glyph has zero contours, no additional glyph
                    // > data beyond the header is required. A glyph with
                    // > zero contours may have additional data, however;
                    // > in particular, it may have instructions that
                    // > operate on phantom points.
                    //
                    // If our number of contours is 0, and there's less than
                    // two bytes in the remaining data, then we just return
                    // the size of the header as our size. The reason for
                    // two bytes is because that's the minimum size of the
                    // extra data, since `instructionLength` is 16 bits.
                    if (num_contours == 0 and self.data.len < 2) {
                        return @sizeOf(Header);
                    }

                    // uint16 endPtsOfContours[numberOfContours]
                    //
                    // Array of point indices for the last point
                    // of each contour, in increasing numeric order.
                    var max_point_index: isize = -1;
                    for (0..num_contours) |_| {
                        const index = try reader.readInt(sfnt.uint16, .big);
                        // The endpoints are supposed to monotonically increase.
                        if (index <= max_point_index) return error.EndPointsOutOfOrder;
                        max_point_index = index;
                    }

                    // uint16 instructionLength
                    //
                    // Total number of bytes for instructions.
                    //
                    // If instructionLength is zero, no instructions
                    // are present for this glyph, and this field is
                    // followed directly by the flags field.
                    const instructions_length = try reader.readInt(sfnt.uint16, .big);

                    // Since we don't have code that validates instruction
                    // byte code, we just reject all glyphs that contain any.
                    //
                    // In the future we could change this to just ignore the
                    // instructions, or even validate them, but for now this
                    // is fine, since we only need this function at all to
                    // validate glyf entries from the glyph protocol, which
                    // explicitly forbids instructions anyway.
                    if (instructions_length > 0) return error.InstructionsNotSupported;

                    // uint8 flags[variable]
                    //
                    // Array of flag elements.
                    //
                    // ---
                    //
                    // We do additional accounting here to figure out how many
                    // bytes the next two fields (the [x|y]Coordinates arrays)
                    // should take, so that we can just try to throw out that
                    // many bytes in order to validate them. This is because
                    // the length of each one depends on the flags.
                    //
                    // We're using `i` here to count the number of logical
                    // entries we have, which should reach the number of
                    // points defined by the final endpoint (from earlier).
                    var i: usize = 0;
                    var x_coords_len: usize = 0;
                    var y_coords_len: usize = 0;
                    while (i <= max_point_index) : (i += 1) {
                        const flag: SimpleFlags = @bitCast(try reader.readByte());

                        // Determine how many bytes the x and y coordinates will
                        // be represented with in the corresponding arrays, add
                        // them to our tallies.
                        x_coords_len += flag.xBytes();
                        y_coords_len += flag.yBytes();

                        // 0x08 REPEAT_FLAG
                        // Bit 3: If set, the next byte (read as unsigned)
                        // specifies the number of additional times this flag
                        // byte is to be repeated in the logical flags array
                        // — that is, the number of additional logical flag
                        // entries inserted after this entry.
                        if (flag.repeat) {
                            // The flag is repeated a certain number of times,
                            // which means that the point count is increased by
                            // that count, and the x_coords_len and y_coords_len
                            // must be increased by the correct number of bytes
                            // as well.
                            const repeat_count: usize = try reader.readByte();
                            i += repeat_count;
                            x_coords_len += repeat_count * flag.xBytes();
                            y_coords_len += repeat_count * flag.yBytes();

                            // If the repeat count pushes our logical point
                            // number beyond the max point index which we
                            // figured out earlier from the end points, then
                            // there's an issue with this entry, error out.
                            if (i > max_point_index) return error.TooManyPoints;
                        }
                    }

                    // uint8 or int16 xCoordinates[variable]
                    //
                    // Contour point x-coordinates.
                    //
                    // ---
                    //
                    // We determined the length of this section (in bytes)
                    // above while processing the flags, so that we can just
                    // skip that many bytes to validate this field.
                    try reader.skipBytes(x_coords_len, .{});

                    // uint8 or int16 yCoordinates[variable]
                    //
                    // Contour point y-coordinates.
                    //
                    // ---
                    //
                    // We determined the length of this section (in bytes)
                    // above while processing the flags, so that we can just
                    // skip that many bytes to validate this field.
                    try reader.skipBytes(y_coords_len, .{});
                },

                .composite => {
                    // We don't have code for validating composite glyphs,
                    // mainly because we don't need it, since we only use
                    // this function for the glyph protocol which explicitly
                    // forbids composite glyphs anyway.
                    //
                    // So we return false for composite glyphs.
                    return error.CompositeNotSupported;
                },
            }

            // No issues found, the glyf entry is valid, return its length.
            return @sizeOf(Header) + fbs.pos;
        }
    };

    /// Initialize the table from the provided data.
    ///
    /// This DOES NOT COPY the data, it only stores a pointer to it.
    ///
    /// The lifetime of this struct, then, is the same as the
    /// lifetime of the data that is used to initialize it.
    pub fn init(data: []const u8) Glyf {
        return .{ .data = data };
    }

    /// Retrieve the entry at the provided offset.
    pub fn entry(self: Glyf, index: usize) error{EndOfStream}!Entry {
        return try Entry.init(self.data[index..]);
    }
};

/// TESTING ONLY
///
/// Retrieves the glyf at the provided index from the provided font.
///
/// Returns it in a tuple with the expected length based on the loca table, and the entry.
pub fn getGlyph(font: sfnt.SFNT, index: usize) !struct { usize, Glyf.Entry } {
    comptime if (!@import("builtin").is_test)
        @compileError("This function is for testing only! It doesn't check bounds or anything!");

    const glyf = Glyf.init(font.getTable("glyf").?);
    const head = try @import("head.zig").Head.init(font.getTable("head").?);
    const loca = font.getTable("loca").?;

    const start_offset = switch (head.indexToLocFormat) {
        0 => @as(usize, std.mem.bigToNative(
            u16,
            std.mem.bytesAsSlice(u16, loca)[index],
        )) * 2,
        1 => @as(usize, std.mem.bigToNative(
            u32,
            std.mem.bytesAsSlice(u32, loca)[index],
        )),
        else => unreachable,
    };

    const end_offset = switch (head.indexToLocFormat) {
        0 => @as(usize, std.mem.bigToNative(
            u16,
            std.mem.bytesAsSlice(u16, loca)[index + 1],
        )) * 2,
        1 => @as(usize, std.mem.bigToNative(
            u32,
            std.mem.bytesAsSlice(u32, loca)[index + 1],
        )),
        else => unreachable,
    };

    return .{ end_offset - start_offset, try glyf.entry(start_offset) };
}

test "glyf" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Cozette because it doesn't have any hinting.
    const test_font = @import("../embedded.zig").cozette;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    // Cozette doesn't actually include a glyph for notdef,
    // but does include a glyph for `\0` (nul), at index 1.
    const len_nul, const glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    // It is legal for there to be extra data between two entries, just
    // as long as the next entry starts after the previous one ends, so
    // it's okay for the parsed size of the entry to be less than the size
    // determined from the difference between subsequent loca offsets.
    try testing.expect(len_nul >= try glyph_nul.size());

    // Glyph "A" is at index 66.
    const len_A, const glyph_A = try getGlyph(font, 66);
    try testing.expect(glyph_A.entryType() == .simple);
    try testing.expect(len_A >= try glyph_A.size());

    // Glyph "Ĩ" is at index 265.
    const len_Itilde, const glyph_Itilde = try getGlyph(font, 265);
    try testing.expect(glyph_Itilde.entryType() == .simple);
    try testing.expect(len_Itilde >= try glyph_Itilde.size());
}

test "glyf: reject glyphs with instructions and composite glyphs" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const test_font = @import("../embedded.zig").jetbrains_mono;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    const len_notdef, const glyph_notdef = try getGlyph(font, 0);
    try testing.expectEqual(100, len_notdef);
    try testing.expect(glyph_notdef.entryType() == .simple);
    try testing.expectError(
        Glyf.Entry.SizeError.InstructionsNotSupported,
        glyph_notdef.size(),
    );

    // Glyph "Á" is at index 2.
    const len_Aacute, const glyph_Aacute = try getGlyph(font, 2);
    try testing.expectEqual(24, len_Aacute);
    try testing.expect(glyph_Aacute.entryType() == .composite);
    try testing.expectError(
        Glyf.Entry.SizeError.CompositeNotSupported,
        glyph_Aacute.size(),
    );
}

test "glyf: reject truncated" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Cozette because it doesn't have any hinting.
    const test_font = @import("../embedded.zig").cozette;

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    // Mess with the entry's data slice, truncating
    // it before the full length (which is 228 bytes).
    glyph_nul.data = glyph_nul.data[0 .. 227 - @sizeOf(Glyf.Entry.Header)];
    try testing.expectError(Glyf.Entry.SizeError.EndOfStream, glyph_nul.size());
}

test "glyf: reject endpoints out of order" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Cozette because it doesn't have any hinting.
    //
    // Also we copy it with the allocator so we can mess with it.
    const test_font = try alloc.dupe(u8, @import("../embedded.zig").cozette[0..]);
    defer alloc.free(test_font);

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    // Mess with the entry's data, insert a 0 in the middle of the endpoints.
    //
    // Because we know the underlying data is something we
    // copied, we can just const cast it back to mutable lol.
    std.mem.bytesAsSlice(u16, @as([]u8, @constCast(glyph_nul.data)))[3] = 0;
    try testing.expectError(Glyf.Entry.SizeError.EndPointsOutOfOrder, glyph_nul.size());
}

test "glyf: reject too many points" {
    const testing = std.testing;
    const alloc = testing.allocator;
    // Cozette because it doesn't have any hinting.
    //
    // Also we copy it with the allocator so we can mess with it.
    const test_font = try alloc.dupe(u8, @import("../embedded.zig").cozette[0..]);
    defer alloc.free(test_font);

    const font = try sfnt.SFNT.init(test_font, alloc);
    defer font.deinit(alloc);

    _, var glyph_nul = try getGlyph(font, 1);
    try testing.expect(glyph_nul.entryType() == .simple);
    // Mess with the entry's data, make the final two bytes of the flags
    // array be a large number repeat to exceed the correct points count.
    //
    // Because we know the underlying data is something we
    // copied, we can just const cast it back to mutable lol.
    @as([]u8, @constCast(glyph_nul.data))[107] |= 0x08;
    @as([]u8, @constCast(glyph_nul.data))[108] = 0xFF;
    try testing.expectError(Glyf.Entry.SizeError.TooManyPoints, glyph_nul.size());
}

test "glyf: zero-contour glyph can be header-only" {
    const testing = std.testing;

    const header: Glyf.Entry.Header = .{
        .numberOfContours = 0,
        .xMin = 0,
        .yMin = 0,
        .xMax = 0,
        .yMax = 0,
    };
    const glyph = try Glyf.Entry.init(std.mem.asBytes(&header));
    try testing.expectEqual(@sizeOf(Glyf.Entry.Header), try glyph.size());
}
