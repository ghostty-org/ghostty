const std = @import("std");
const Allocator = std.mem.Allocator;
const sfnt = @import("sfnt.zig");
const compat_reader = @import("../../lib/compat/reader.zig");

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

    /// A decoded glyph outline.
    ///
    /// The `contours` slice is the list of end point indices and
    /// `points` owns all the points. Glyf guarantees that contour
    /// points are sequential so we can just store the end and calculate
    /// the points that way. Use the helpers to make it ergonomic.
    pub const Outline = struct {
        /// List of contour end points. Calculate the full list of
        /// points using points[prev...this+1]
        contours: []const sfnt.uint16,

        /// The backing storage of all points in the entry.
        points: []const Point,

        /// A single decoded point in a simple glyph contour.
        pub const Point = struct {
            x: i32,
            y: i32,
            on_curve: bool,
        };

        /// Return the point slice for the contour at `index`.
        ///
        /// The returned slice references `points` and is invalidated when
        /// this outline is deinitialized.
        pub fn contour(self: Outline, index: usize) []const Point {
            const start = if (index == 0)
                0
            else
                @as(usize, self.contours[index - 1]) + 1;
            const end = @as(usize, self.contours[index]) + 1;
            return self.points[start..end];
        }

        /// Free all memory owned by this outline. Pass in the same
        /// allocator used for decoding.
        pub fn deinit(self: *Outline, alloc: Allocator) void {
            alloc.free(self.contours);
            alloc.free(self.points);
            self.* = undefined;
        }
    };

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
        pub fn init(data: []const u8) std.Io.Reader.Error!Entry {
            var reader: std.Io.Reader = .fixed(data);
            const header = try compat_reader.readStructEndian(&reader, Header, .big);
            return .{ .header = header, .data = data[@sizeOf(Header)..] };
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
        } || std.Io.Reader.Error;

        /// Errors that can be returned from `Entry.decode()`.
        pub const DecodeError = SizeError || Allocator.Error || error{
            /// Coordinate delta accumulation overflowed.
            CoordinateOverflow,
        };

        /// Determines the size (in bytes) of this entry.
        ///
        /// If the entry is valid, returns the number of bytes
        /// taken up by this entry, including its header.
        ///
        /// NOTE: Currently produces errors when given composite glyphs
        ///       or any glyphs that have hinting instructions included.
        pub fn size(self: Entry) SizeError!usize {
            var reader: std.Io.Reader = .fixed(self.data);
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
                        const index = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
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
                    const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);

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
                        const flag: SimpleFlags = @bitCast(try compat_reader.readByte(&reader));

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
                            const repeat_count: usize = try compat_reader.readByte(&reader);
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
                    try compat_reader.readSkipBytes(&reader, x_coords_len);

                    // uint8 or int16 yCoordinates[variable]
                    //
                    // Contour point y-coordinates.
                    //
                    // ---
                    //
                    // We determined the length of this section (in bytes)
                    // above while processing the flags, so that we can just
                    // skip that many bytes to validate this field.
                    try compat_reader.readSkipBytes(&reader, y_coords_len);
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
            return @sizeOf(Header) + reader.seek;
        }

        /// Decode this simple glyph entry into an owned outline.
        ///
        /// NOTE: Currently produces errors when given composite glyphs
        ///       or any glyphs that have hinting instructions included.
        pub fn decode(self: Entry, alloc: Allocator) DecodeError!Glyf.Outline {
            // We only support simple glyphs.
            switch (self.entryType()) {
                .simple => {},
                .composite => return error.CompositeNotSupported,
            }

            var reader: std.Io.Reader = .fixed(self.data);

            // A zero-contour glyph may be header-only. See size for the
            // reason for the hardcoded 2 here.
            const num_contours: usize = @intCast(self.header.numberOfContours);
            if (num_contours == 0 and self.data.len < 2) return .{
                .points = &.{},
                .contours = &.{},
            };

            // We now know our full amount of contour ending points.
            const end_points = try alloc.alloc(sfnt.uint16, num_contours);
            errdefer alloc.free(end_points);

            // If we have no contours, then the only possible remaining
            // field is instructionLength. Instructions are not supported.
            if (num_contours == 0) {
                const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                if (instructions_length > 0) return error.InstructionsNotSupported;
                return .{ .points = &.{}, .contours = end_points };
            }

            // The number of points is determined by the final end point
            // entry since the entries have to be monotonic (something
            // we verify below).
            const point_count: usize = point_count: {
                var prev_end_point: isize = -1;

                // Go through the end points array and update our end_points
                // with the valid index. The final endpoint tells us our point
                // count, since endpoints are stored as inclusive point indices.
                for (0..end_points.len) |i| {
                    const index = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
                    if (index <= prev_end_point) return error.EndPointsOutOfOrder;
                    prev_end_point = index;
                    end_points[i] = index;
                }

                // The final point tells us our point count.
                break :point_count @as(usize, end_points[end_points.len - 1]) + 1;
            };

            // Instructions are not supported.
            const instructions_length = try compat_reader.readerInt(&reader, sfnt.uint16, .big);
            if (instructions_length > 0) return error.InstructionsNotSupported;

            // Allocate our points right away even though the next entries
            // are flags. We want to do this so that if the allocator is
            // a bump allocator, the flags free will actually free it.
            const points = try alloc.alloc(Glyf.Outline.Point, point_count);
            errdefer alloc.free(points);

            // This is EXTREMELY annoying but all the flags are separate
            // from the points so we have to do some allocation here since
            // its a dynamic amount and we need to save the values for later.
            //
            // Typical glyphs have small point counts, so use stack storage
            // first while still falling back to the caller's allocator for
            // unusually large outlines.
            var flags_stack = std.heap.stackFallback(4096, alloc);
            const flags_alloc = flags_stack.get();
            const flags = try flags_alloc.alloc(SimpleFlags, point_count);
            defer flags_alloc.free(flags);
            {
                var point_i: usize = 0;
                while (point_i < point_count) {
                    const flag: SimpleFlags = @bitCast(try compat_reader.readByte(&reader));
                    flags[point_i] = flag;
                    point_i += 1;

                    if (flag.repeat) {
                        const repeat_count: usize = try compat_reader.readByte(&reader);
                        if (point_i + repeat_count > point_count) return error.TooManyPoints;

                        for (0..repeat_count) |_| {
                            flags[point_i] = flag;
                            point_i += 1;
                        }
                    }
                }
            }

            // Go through x coordinate deltas
            var x: i32 = 0;
            for (flags, points) |flag, *point| {
                const dx: i32 = if (flag.x_short) short: {
                    break :short if (flag.x_repeat_or_sign)
                        @as(i32, try compat_reader.readByte(&reader))
                    else
                        -@as(i32, try compat_reader.readByte(&reader));
                } else if (!flag.x_repeat_or_sign)
                    @as(i32, try compat_reader.readerInt(&reader, sfnt.int16, .big))
                else
                    0;

                x = std.math.add(
                    i32,
                    x,
                    dx,
                ) catch return error.CoordinateOverflow;
                point.x = x;
            }

            // Go through y coordinate deltas
            var y: i32 = 0;
            for (flags, points) |flag, *point| {
                const dy: i32 = if (flag.y_short) short: {
                    break :short if (flag.y_repeat_or_sign)
                        @as(i32, try compat_reader.readByte(&reader))
                    else
                        -@as(i32, try compat_reader.readByte(&reader));
                } else if (!flag.y_repeat_or_sign)
                    @as(i32, try compat_reader.readerInt(&reader, sfnt.int16, .big))
                else
                    0;

                y = std.math.add(
                    i32,
                    y,
                    dy,
                ) catch return error.CoordinateOverflow;
                point.y = y;
                point.on_curve = flag.on_curve;
            }

            return .{
                .points = points,
                .contours = end_points,
            };
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
    pub fn entry(self: Glyf, index: usize) std.Io.Reader.Error!Entry {
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

fn testAppendInt(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    comptime T: type,
    value: T,
) !void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .big);
    try buf.appendSlice(alloc, &bytes);
}

fn testAppendHeader(
    buf: *std.ArrayList(u8),
    alloc: Allocator,
    number_of_contours: i16,
    x_min: i16,
    y_min: i16,
    x_max: i16,
    y_max: i16,
) !void {
    try testAppendInt(buf, alloc, i16, number_of_contours);
    try testAppendInt(buf, alloc, i16, x_min);
    try testAppendInt(buf, alloc, i16, y_min);
    try testAppendInt(buf, alloc, i16, x_max);
    try testAppendInt(buf, alloc, i16, y_max);
}

test "glyf" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

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

    var outline_A = try glyph_A.decode(alloc);
    defer outline_A.deinit(alloc);
    try testing.expectEqual(@as(usize, @intCast(glyph_A.header.numberOfContours)), outline_A.contours.len);
    try testing.expect(outline_A.points.len > 0);

    // Glyph "Ĩ" is at index 265.
    const len_Itilde, const glyph_Itilde = try getGlyph(font, 265);
    try testing.expect(glyph_Itilde.entryType() == .simple);
    try testing.expect(len_Itilde >= try glyph_Itilde.size());
}

test "glyf: decode triangle" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 1, 100, 100, 900, 900);
    try testAppendInt(&buf, alloc, u16, 2); // endPtsOfContours[0]
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength
    try buf.append(alloc, 0x01); // on curve
    try buf.append(alloc, 0x01); // on curve
    try buf.append(alloc, 0x01); // on curve
    try testAppendInt(&buf, alloc, i16, 500);
    try testAppendInt(&buf, alloc, i16, -400);
    try testAppendInt(&buf, alloc, i16, 800);
    try testAppendInt(&buf, alloc, i16, 900);
    try testAppendInt(&buf, alloc, i16, -800);
    try testAppendInt(&buf, alloc, i16, 0);

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(@as(i16, 100), glyph.header.xMin);
    try testing.expectEqual(@as(i16, 900), glyph.header.xMax);
    try testing.expectEqual(@as(usize, 1), outline.contours.len);
    try testing.expectEqual(@as(usize, 3), outline.points.len);
    const contour = outline.contour(0);
    try testing.expectEqual(@as(usize, 3), contour.len);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 500, .y = 900, .on_curve = true }, contour[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 100, .y = 100, .on_curve = true }, contour[1]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 900, .y = 100, .on_curve = true }, contour[2]);
}

test "glyf: decode multiple contours" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 2, 0, 0, 30, 10);
    try testAppendInt(&buf, alloc, u16, 1); // first contour ends at point 1
    try testAppendInt(&buf, alloc, u16, 3); // second contour ends at point 3
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength
    for (0..4) |_| try buf.append(alloc, 0x01); // on curve
    for ([_]i16{ 0, 10, 10, 10 }) |dx| try testAppendInt(&buf, alloc, i16, dx);
    for ([_]i16{ 0, 0, 10, 0 }) |dy| try testAppendInt(&buf, alloc, i16, dy);

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(@as(usize, 2), outline.contours.len);
    try testing.expectEqual(@as(usize, 4), outline.points.len);
    try testing.expectEqual(@as(u16, 1), outline.contours[0]);
    try testing.expectEqual(@as(u16, 3), outline.contours[1]);
    try testing.expectEqual(@as(usize, 2), outline.contour(0).len);
    try testing.expectEqual(@as(usize, 2), outline.contour(1).len);
    try testing.expectEqual(outline.points[0..2].ptr, outline.contour(0).ptr);
    try testing.expectEqual(outline.points[2..4].ptr, outline.contour(1).ptr);
}

test "glyf: decode repeat and short vector flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 1, 0, -16, 16, 0);
    try testAppendInt(&buf, alloc, u16, 3); // four points
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength
    try buf.append(alloc, 0x01 | 0x02 | 0x04 | 0x08 | 0x10); // on, x short positive, y short negative, repeat
    try buf.append(alloc, 3); // repeat for the next three points
    for ([_]u8{ 1, 2, 4, 8 }) |dx| try buf.append(alloc, dx);
    for ([_]u8{ 1, 2, 4, 8 }) |dy| try buf.append(alloc, dy);

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(@as(usize, 4), outline.points.len);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 1, .y = -1, .on_curve = true }, outline.points[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 3, .y = -3, .on_curve = true }, outline.points[1]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 7, .y = -7, .on_curve = true }, outline.points[2]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 15, .y = -15, .on_curve = true }, outline.points[3]);
}

test "glyf: decode off curve and same coordinate flags" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 1, 0, 0, 7, 9);
    try testAppendInt(&buf, alloc, u16, 1); // two points
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength
    try buf.append(alloc, 0x10 | 0x20); // off curve, x same, y same
    try buf.append(alloc, 0x01 | 0x02 | 0x04 | 0x10 | 0x20); // on curve, short positive x/y
    try buf.append(alloc, 7); // x delta
    try buf.append(alloc, 9); // y delta

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(Glyf.Outline.Point{ .x = 0, .y = 0, .on_curve = false }, outline.points[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 7, .y = 9, .on_curve = true }, outline.points[1]);
}

test "glyf: decode one-point contour" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 1, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 0); // endPtsOfContours[0]
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength
    try buf.append(alloc, 0x01 | 0x10 | 0x20); // on curve, x same, y same

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(@as(usize, 1), outline.points.len);
    try testing.expectEqual(@as(usize, 1), outline.contours.len);
    try testing.expectEqual(@as(u16, 0), outline.contours[0]);
    try testing.expectEqual(Glyf.Outline.Point{ .x = 0, .y = 0, .on_curve = true }, outline.contour(0)[0]);
}

test "glyf: decode contour ending at max point index" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 1, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, std.math.maxInt(u16)); // 65536 points
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength

    const flag = 0x01 | 0x10 | 0x20; // on curve, x same, y same
    var remaining: usize = @as(usize, std.math.maxInt(u16)) + 1;
    while (remaining > 0) {
        const run = @min(remaining, 256);
        if (run == 1) {
            try buf.append(alloc, flag);
        } else {
            try buf.append(alloc, flag | 0x08); // repeat
            try buf.append(alloc, @intCast(run - 1));
        }
        remaining -= run;
    }

    const glyph = try Glyf.Entry.init(buf.items);
    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);

    try testing.expectEqual(@as(usize, 65536), outline.points.len);
    try testing.expectEqual(@as(usize, 65536), outline.contour(0).len);
}

test "glyf: reject glyphs with instructions and composite glyphs" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

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
    try testing.expectError(
        Glyf.Entry.DecodeError.InstructionsNotSupported,
        glyph_notdef.decode(alloc),
    );

    // Glyph "Á" is at index 2.
    const len_Aacute, const glyph_Aacute = try getGlyph(font, 2);
    try testing.expectEqual(24, len_Aacute);
    try testing.expect(glyph_Aacute.entryType() == .composite);
    try testing.expectError(
        Glyf.Entry.SizeError.CompositeNotSupported,
        glyph_Aacute.size(),
    );
    try testing.expectError(
        Glyf.Entry.DecodeError.CompositeNotSupported,
        glyph_Aacute.decode(alloc),
    );
}

test "glyf: reject truncated" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

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
    try testing.expectError(Glyf.Entry.DecodeError.EndOfStream, glyph_nul.decode(alloc));
}

test "glyf: reject endpoints out of order" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

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
    try testing.expectError(
        Glyf.Entry.DecodeError.EndPointsOutOfOrder,
        glyph_nul.decode(alloc),
    );
}

test "glyf: reject too many points" {
    // lib-vt source archives intentionally exclude full Ghostty font fixtures.
    if (comptime @import("terminal_options").artifact == .lib) return error.SkipZigTest;

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
    try testing.expectError(Glyf.Entry.DecodeError.TooManyPoints, glyph_nul.decode(alloc));
}

test "glyf: zero-contour glyph can be header-only" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const header: Glyf.Entry.Header = .{
        .numberOfContours = 0,
        .xMin = 0,
        .yMin = 0,
        .xMax = 0,
        .yMax = 0,
    };
    const glyph = try Glyf.Entry.init(std.mem.asBytes(&header));
    try testing.expectEqual(@sizeOf(Glyf.Entry.Header), try glyph.size());

    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), outline.points.len);
    try testing.expectEqual(@as(usize, 0), outline.contours.len);
}

test "glyf: zero-contour glyph can include instruction length" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 0, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 0); // instructionLength

    const glyph = try Glyf.Entry.init(buf.items);
    try testing.expectEqual(@sizeOf(Glyf.Entry.Header) + 2, try glyph.size());

    var outline = try glyph.decode(alloc);
    defer outline.deinit(alloc);
    try testing.expectEqual(@as(usize, 0), outline.points.len);
    try testing.expectEqual(@as(usize, 0), outline.contours.len);
}

test "glyf: zero-contour glyph rejects instructions" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);

    try testAppendHeader(&buf, alloc, 0, 0, 0, 0, 0);
    try testAppendInt(&buf, alloc, u16, 1); // instructionLength

    const glyph = try Glyf.Entry.init(buf.items);
    try testing.expectError(Glyf.Entry.SizeError.InstructionsNotSupported, glyph.size());
    try testing.expectError(Glyf.Entry.DecodeError.InstructionsNotSupported, glyph.decode(alloc));
}
