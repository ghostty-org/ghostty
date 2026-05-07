//! OpenType `glyf` simple-glyph decoder.
//!
//! Parses a bare TrueType simple-glyph record (as shipped over the Glyph
//! Protocol wire) into a neutral `Outline`. The glyf record format is
//! specified in the OpenType spec:
//!
//!   <https://learn.microsoft.com/en-us/typography/opentype/spec/glyf>
//!
//! The protocol only accepts the subset defined in Glyph Protocol §8.2:
//! simple glyphs only, no composites, no hinting instructions, standard
//! flag encoding with the REPEAT bit.
//!
//! The decoder walks the record; rasterization is left to the renderer.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A single decoded contour point in the glyph's authoring coordinate
/// space (bottom-left origin, Y-up).
pub const Point = struct {
    x: i32,
    y: i32,
    on_curve: bool,
};

/// A fully-decoded simple glyph: a sequence of closed contours plus the
/// glyph's bounding box. The backing `points` slice owns storage for
/// every point; each entry in `contours` is a subslice of it. Free with
/// `deinit`.
pub const Outline = struct {
    contours: [][]Point,
    points: []Point,
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,

    pub fn deinit(self: *Outline, alloc: Allocator) void {
        alloc.free(self.contours);
        alloc.free(self.points);
        self.* = undefined;
    }
};

/// Reasons a glyf record is rejected. Maps onto Glyph Protocol `reason=`
/// codes via `reasonString`.
pub const DecodeError = error{
    /// numberOfContours < 0 — record is a composite glyph reference.
    Composite,
    /// instructionLength != 0 — hinting bytecode is present.
    Hinted,
    /// Truncated payload or a structural invariant was violated.
    Malformed,
} || Allocator.Error;

/// Map a decoder error to the spec `reason=` string, or `null` for
/// allocation failures (no spec reason).
pub fn reasonString(err: DecodeError) ?[]const u8 {
    return switch (err) {
        error.Composite => "composite_unsupported",
        error.Hinted => "hinting_unsupported",
        error.Malformed => "malformed_payload",
        error.OutOfMemory => null,
    };
}

// glyf simple-glyph flag bits (OpenType spec).
const FLAG_ON_CURVE: u8 = 0x01;
const FLAG_X_SHORT: u8 = 0x02;
const FLAG_Y_SHORT: u8 = 0x04;
const FLAG_REPEAT: u8 = 0x08;
const FLAG_X_SAME_OR_POS: u8 = 0x10;
const FLAG_Y_SAME_OR_POS: u8 = 0x20;

/// Decode a simple-glyph record. The returned `Outline` owns its
/// allocations; callers must `deinit`.
pub fn decode(alloc: Allocator, data: []const u8) DecodeError!Outline {
    var r: Reader = .{ .data = data };

    const num_contours_raw = try r.i16be();
    if (num_contours_raw < 0) return error.Composite;
    const num_contours: usize = @intCast(num_contours_raw);

    const x_min = try r.i16be();
    const y_min = try r.i16be();
    const x_max = try r.i16be();
    const y_max = try r.i16be();

    // An empty glyph (numberOfContours == 0) is structurally valid: the
    // bounding box is the only remaining field. Used for rendering
    // nothing at a codepoint, e.g. the null glyph.
    if (num_contours == 0) {
        return .{
            .contours = &.{},
            .points = &.{},
            .x_min = x_min,
            .y_min = y_min,
            .x_max = x_max,
            .y_max = y_max,
        };
    }

    // endPtsOfContours[] + instructionLength.
    const end_pts = try alloc.alloc(u16, num_contours);
    defer alloc.free(end_pts);
    for (end_pts) |*e| e.* = try r.u16be();

    // End points must be strictly increasing; otherwise two contours
    // would share a point and the contour-slice split below would
    // produce empty or backwards contours.
    var ci: usize = 1;
    while (ci < end_pts.len) : (ci += 1) {
        if (end_pts[ci] <= end_pts[ci - 1]) return error.Malformed;
    }

    const instr_len = try r.u16be();
    if (instr_len != 0) return error.Hinted;

    const num_points: usize = @as(usize, end_pts[end_pts.len - 1]) + 1;

    // Flags, with REPEAT expansion.
    const flags = try alloc.alloc(u8, num_points);
    defer alloc.free(flags);
    {
        var idx: usize = 0;
        while (idx < num_points) {
            const f = try r.byte();
            flags[idx] = f;
            idx += 1;
            if (f & FLAG_REPEAT != 0) {
                const count = try r.byte();
                if (idx + count > num_points) return error.Malformed;
                var k: u8 = 0;
                while (k < count) : (k += 1) {
                    flags[idx] = f;
                    idx += 1;
                }
            }
        }
    }

    const points = try alloc.alloc(Point, num_points);
    errdefer alloc.free(points);

    // X coordinates: delta encoding with SHORT (u8) / SAME_OR_POS
    // fallback. See OpenType glyf §Simple Glyph Flags.
    var cx: i32 = 0;
    for (flags, 0..) |f, p| {
        var dx: i32 = 0;
        if (f & FLAG_X_SHORT != 0) {
            const v = try r.byte();
            dx = if (f & FLAG_X_SAME_OR_POS != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & FLAG_X_SAME_OR_POS == 0) {
            dx = try r.i16be();
        }
        cx += dx;
        points[p].x = cx;
    }

    // Y coordinates, same scheme.
    var cy: i32 = 0;
    for (flags, 0..) |f, p| {
        var dy: i32 = 0;
        if (f & FLAG_Y_SHORT != 0) {
            const v = try r.byte();
            dy = if (f & FLAG_Y_SAME_OR_POS != 0) @as(i32, v) else -@as(i32, v);
        } else if (f & FLAG_Y_SAME_OR_POS == 0) {
            dy = try r.i16be();
        }
        cy += dy;
        points[p].y = cy;
        points[p].on_curve = (flags[p] & FLAG_ON_CURVE) != 0;
    }

    const contours = try alloc.alloc([]Point, end_pts.len);
    errdefer alloc.free(contours);

    var pidx: usize = 0;
    for (end_pts, 0..) |end, i| {
        const len = @as(usize, end) - pidx + 1;
        contours[i] = points[pidx .. pidx + len];
        pidx += len;
    }

    return .{
        .contours = contours,
        .points = points,
        .x_min = x_min,
        .y_min = y_min,
        .x_max = x_max,
        .y_max = y_max,
    };
}

/// Big-endian byte cursor used by the decoder.
const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn need(self: *Reader, n: usize) error{Malformed}!void {
        if (self.data.len - self.pos < n) return error.Malformed;
    }

    fn byte(self: *Reader) error{Malformed}!u8 {
        try self.need(1);
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }

    fn u16be(self: *Reader) error{Malformed}!u16 {
        try self.need(2);
        const hi: u16 = self.data[self.pos];
        const lo: u16 = self.data[self.pos + 1];
        self.pos += 2;
        return (hi << 8) | lo;
    }

    fn i16be(self: *Reader) error{Malformed}!i16 {
        return @bitCast(try self.u16be());
    }
};

const testing = std.testing;

// Flag bits duplicated for tests that hand-encode glyf records without
// reaching into the decoder internals.
const T_FLAG_ON_CURVE: u8 = 0x01;
const T_FLAG_REPEAT: u8 = 0x08;

fn pushBe(buf: *std.ArrayList(u8), comptime T: type, v: T) !void {
    var arr: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &arr, v, .big);
    try buf.appendSlice(testing.allocator, &arr);
}

fn triangleBytes(buf: *std.ArrayList(u8)) !void {
    // Single on-curve-triangle contour, hand-encoded. Mirrors rio's
    // glyf_decode.rs reference test.
    try pushBe(buf, i16, 1); // numberOfContours
    try pushBe(buf, i16, 100); // xMin
    try pushBe(buf, i16, 100); // yMin
    try pushBe(buf, i16, 900); // xMax
    try pushBe(buf, i16, 900); // yMax
    try pushBe(buf, u16, 2); // endPtsOfContours[0]
    try pushBe(buf, u16, 0); // instructionLength
    try buf.append(testing.allocator, T_FLAG_ON_CURVE);
    try buf.append(testing.allocator, T_FLAG_ON_CURVE);
    try buf.append(testing.allocator, T_FLAG_ON_CURVE);
    // X deltas: 500, -400, 800 as signed i16 BE.
    try pushBe(buf, i16, 500);
    try pushBe(buf, i16, -400);
    try pushBe(buf, i16, 800);
    // Y deltas: 900, -800, 0.
    try pushBe(buf, i16, 900);
    try pushBe(buf, i16, -800);
    try pushBe(buf, i16, 0);
}

test "decode triangle" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try triangleBytes(&buf);

    var out = try decode(testing.allocator, buf.items);
    defer out.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 1), out.contours.len);
    try testing.expectEqual(@as(i32, 100), out.x_min);
    try testing.expectEqual(@as(i32, 900), out.x_max);
    const c = out.contours[0];
    try testing.expectEqual(@as(usize, 3), c.len);
    try testing.expectEqual(Point{ .x = 500, .y = 900, .on_curve = true }, c[0]);
    try testing.expectEqual(Point{ .x = 100, .y = 100, .on_curve = true }, c[1]);
    try testing.expectEqual(Point{ .x = 900, .y = 100, .on_curve = true }, c[2]);
}

test "decode rejects composite" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, -1);
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8);

    try testing.expectError(error.Composite, decode(testing.allocator, buf.items));
}

test "decode rejects hinting" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 1);
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8); // bbox
    try pushBe(&buf, u16, 0); // endPts[0]
    try pushBe(&buf, u16, 1); // instructionLength=1
    try buf.append(testing.allocator, 0x00); // one instruction byte
    try buf.append(testing.allocator, T_FLAG_ON_CURVE);
    try pushBe(&buf, i16, 0);
    try pushBe(&buf, i16, 0);

    try testing.expectError(error.Hinted, decode(testing.allocator, buf.items));
}

test "decode rejects truncated" {
    try testing.expectError(error.Malformed, decode(testing.allocator, &.{}));

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 1);
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8);
    // No endPts / instruction / flags / coords.
    try testing.expectError(error.Malformed, decode(testing.allocator, buf.items));
}

test "decode handles REPEAT flag" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 1); // 1 contour
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8); // bbox
    try pushBe(&buf, u16, 3); // endPts[0]=3 → 4 points
    try pushBe(&buf, u16, 0); // instructionLength
    // 4 points with identical flags, encoded as one flag byte + REPEAT count 3.
    try buf.append(testing.allocator, T_FLAG_ON_CURVE | T_FLAG_REPEAT);
    try buf.append(testing.allocator, 3);
    for ([_]i16{ 10, 10, 10, 10 }) |dx| try pushBe(&buf, i16, dx);
    for ([_]i16{ 0, 10, 0, -10 }) |dy| try pushBe(&buf, i16, dy);

    var out = try decode(testing.allocator, buf.items);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), out.contours[0].len);
    try testing.expectEqual(@as(i32, 40), out.contours[0][3].x);
    try testing.expectEqual(@as(i32, 0), out.contours[0][3].y);
}

test "decode short-vector x and y" {
    // Two-point contour using X_SHORT with SAME_OR_POS (positive) and
    // Y_SHORT without SAME_OR_POS (negative) to exercise both branches.
    const FLAG_X_SHORT_POS = FLAG_X_SHORT | FLAG_X_SAME_OR_POS | FLAG_ON_CURVE;
    const FLAG_Y_SHORT_NEG = FLAG_Y_SHORT | FLAG_ON_CURVE; // negative short
    const flag = FLAG_X_SHORT_POS | FLAG_Y_SHORT_NEG;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 1);
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8);
    try pushBe(&buf, u16, 1); // endPts[0]=1
    try pushBe(&buf, u16, 0);
    try buf.append(testing.allocator, flag);
    try buf.append(testing.allocator, flag);
    try buf.append(testing.allocator, 50); // x delta +50
    try buf.append(testing.allocator, 25); // x delta +25
    try buf.append(testing.allocator, 30); // y delta -30 (short, not same_or_pos)
    try buf.append(testing.allocator, 5); //  y delta -5

    var out = try decode(testing.allocator, buf.items);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(i32, 50), out.contours[0][0].x);
    try testing.expectEqual(@as(i32, 75), out.contours[0][1].x);
    try testing.expectEqual(@as(i32, -30), out.contours[0][0].y);
    try testing.expectEqual(@as(i32, -35), out.contours[0][1].y);
}

test "decode rejects non-increasing end points" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 2); // 2 contours
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8);
    try pushBe(&buf, u16, 3); // endPts[0]
    try pushBe(&buf, u16, 3); // endPts[1] == endPts[0] — invalid
    try pushBe(&buf, u16, 0);

    try testing.expectError(error.Malformed, decode(testing.allocator, buf.items));
}

test "decode empty glyph" {
    // numberOfContours == 0 is valid — the bbox is still present but
    // there are no end_pts / flags / coords.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushBe(&buf, i16, 0);
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 8);

    var out = try decode(testing.allocator, buf.items);
    defer out.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), out.contours.len);
}

test "reasonString covers every spec code" {
    try testing.expectEqualStrings("composite_unsupported", reasonString(error.Composite).?);
    try testing.expectEqualStrings("hinting_unsupported", reasonString(error.Hinted).?);
    try testing.expectEqualStrings("malformed_payload", reasonString(error.Malformed).?);
    try testing.expect(reasonString(error.OutOfMemory) == null);
}
