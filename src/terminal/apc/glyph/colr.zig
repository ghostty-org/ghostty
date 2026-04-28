//! Glyph Protocol COLR/CPAL support.
//!
//! Two distinct things live in this module:
//!
//!   1. **Container** — the sidecar wire format the protocol uses to
//!      ship a colour glyph. It prefixes the embedded OpenType `COLR`
//!      and `CPAL` tables with a length-tagged array of `glyf`
//!      outlines so the terminal can resolve every `glyphID` in the
//!      COLR table against our own outline set rather than against
//!      some externally supplied font file. Spec §8.6.
//!
//!   2. **Minimal `COLR` v0 + `CPAL` parsers** — just enough of the
//!      OpenType spec to walk a base glyph's layer list and to look
//!      up palette entries by index. We intentionally don't pull in a
//!      full font parser; the subset is tiny and the terminal only
//!      needs the paint-order walk, not the variations / shaping
//!      machinery a real font library provides.
//!
//! `COLR` v1's paint graph (§8.7) is NOT parsed here yet — the phase
//! that adds v1 rendering will do partial paint-graph support inside
//! the rasterizer. For now v1 payloads parse into the same Container
//! as v0 and the rasterizer degrades to a single-colour render using
//! the first palette entry of the base glyph.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Upper bound on inner glyph outlines carried in one container
/// (spec §8.6, mirrors the per-session glossary cap).
pub const max_outlines: u16 = 1024;

/// Parsed container. Owns every byte slice it references so the
/// rasterizer can hold onto it across frames without worrying about
/// the originating wire buffer.
pub const Container = struct {
    /// Inner glyph outlines, in wire order. Index 0 is the base glyph
    /// rendered when the registered codepoint is emitted; higher
    /// indices are referenced from the `COLR` table's layer records.
    outlines: [][]u8,
    /// OpenType `COLR` table bytes (v0 or v1).
    colr: []u8,
    /// OpenType `CPAL` table bytes. Empty slice is legal for
    /// `fmt=colrv1` (v1 paints can embed sRGBA directly); `fmt=colrv0`
    /// rejects an empty CPAL at parse time.
    cpal: []u8,

    pub fn deinit(self: *Container, alloc: Allocator) void {
        for (self.outlines) |o| alloc.free(o);
        alloc.free(self.outlines);
        alloc.free(self.colr);
        alloc.free(self.cpal);
        self.* = undefined;
    }
};

pub const ParseError = error{
    /// Container or inner table is truncated, has inconsistent sizes,
    /// or violates a structural invariant (e.g. zero-length COLR).
    Malformed,
} || Allocator.Error;

pub const ParseOptions = struct {
    /// Whether the CPAL table must be non-empty. Spec §8.6 requires
    /// CPAL for `fmt=colrv0`; §8.7 makes it optional for `fmt=colrv1`.
    cpal_required: bool,
};

/// Parse the sidecar container described in spec §8.6. All allocations
/// come from `alloc`; on error every partial allocation is freed.
pub fn parseContainer(
    alloc: Allocator,
    data: []const u8,
    opts: ParseOptions,
) ParseError!Container {
    var r: Reader = .{ .data = data };

    const n = try r.u16be();
    if (n == 0 or n > max_outlines) return error.Malformed;

    var outlines = try alloc.alloc([]u8, n);
    var allocated: usize = 0;
    errdefer {
        for (outlines[0..allocated]) |o| alloc.free(o);
        alloc.free(outlines);
    }

    var i: u16 = 0;
    while (i < n) : (i += 1) {
        const glyf_len = try r.u16be();
        const raw = try r.bytes(glyf_len);
        outlines[i] = try alloc.dupe(u8, raw);
        allocated += 1;
    }

    const colr_len = try r.u16be();
    if (colr_len == 0) return error.Malformed;
    const colr_raw = try r.bytes(colr_len);
    const colr = try alloc.dupe(u8, colr_raw);
    errdefer alloc.free(colr);

    const cpal_len = try r.u16be();
    if (opts.cpal_required and cpal_len == 0) return error.Malformed;
    const cpal_raw = try r.bytes(cpal_len);
    const cpal = try alloc.dupe(u8, cpal_raw);
    errdefer alloc.free(cpal);

    // Any trailing bytes means the sender packed extra data we don't
    // understand — reject rather than silently ignore so bugs are
    // visible during integration.
    if (r.remaining() != 0) return error.Malformed;

    return .{
        .outlines = outlines,
        .colr = colr,
        .cpal = cpal,
    };
}

/// OpenType `COLR` v0 table view. References bytes inside `.colr`;
/// lives only as long as the Container that owns those bytes.
pub const ColrV0 = struct {
    /// Backing table bytes. All offsets below are resolved against
    /// this slice.
    bytes: []const u8,
    num_base_records: u16,
    num_layer_records: u16,
    base_offset: usize,
    layer_offset: usize,

    pub const BaseGlyphRecord = struct {
        glyph_id: u16,
        first_layer_index: u16,
        num_layers: u16,
    };

    pub const LayerRecord = struct {
        /// Index into `Container.outlines` for the glyph that renders
        /// this layer.
        glyph_id: u16,
        /// Index into CPAL for the layer's fill colour. `0xFFFF` means
        /// "current foreground" per OpenType spec.
        palette_index: u16,
    };

    /// Find the base glyph record for `glyph_id`. Returns null if no
    /// record exists — caller should treat that as "no COLR entry,
    /// render the base outline in foreground."
    pub fn findBaseGlyph(self: ColrV0, glyph_id: u16) ?BaseGlyphRecord {
        // Records are spec'd as sorted; but the spec also allows binary
        // search. We linear-scan because typical containers carry ≤16
        // base records — fewer than a cache line's worth.
        var i: u16 = 0;
        while (i < self.num_base_records) : (i += 1) {
            const rec = self.baseGlyphAt(i) catch return null;
            if (rec.glyph_id == glyph_id) return rec;
        }
        return null;
    }

    /// Read the `i`th base glyph record.
    pub fn baseGlyphAt(self: ColrV0, i: u16) error{Malformed}!BaseGlyphRecord {
        if (i >= self.num_base_records) return error.Malformed;
        const off = self.base_offset + @as(usize, i) * 6;
        if (off + 6 > self.bytes.len) return error.Malformed;
        return .{
            .glyph_id = readU16(self.bytes[off..][0..2]),
            .first_layer_index = readU16(self.bytes[off + 2 ..][0..2]),
            .num_layers = readU16(self.bytes[off + 4 ..][0..2]),
        };
    }

    /// Read the `i`th layer record (indexes into the flat layer array,
    /// not relative to a specific base record).
    pub fn layerAt(self: ColrV0, i: u16) error{Malformed}!LayerRecord {
        if (i >= self.num_layer_records) return error.Malformed;
        const off = self.layer_offset + @as(usize, i) * 4;
        if (off + 4 > self.bytes.len) return error.Malformed;
        return .{
            .glyph_id = readU16(self.bytes[off..][0..2]),
            .palette_index = readU16(self.bytes[off + 2 ..][0..2]),
        };
    }
};

/// Parse the fixed 14-byte COLR header. Accepts both version 0 and
/// version 1 — COLR v1 extends v0 with a paint graph after the
/// layer records, but the first 14 bytes are the same and many v1
/// fonts still populate the v0-style base / layer records for
/// monochrome-per-layer fallback, which is all this walker reads.
pub fn parseColrV0(colr: []const u8) error{Malformed}!ColrV0 {
    if (colr.len < 14) return error.Malformed;
    const version = readU16(colr[0..2]);
    if (version > 1) return error.Malformed;
    const num_base = readU16(colr[2..4]);
    const base_offset = readU32(colr[4..8]);
    const layer_offset = readU32(colr[8..12]);
    const num_layer = readU16(colr[12..14]);

    return .{
        .bytes = colr,
        .num_base_records = num_base,
        .num_layer_records = num_layer,
        .base_offset = base_offset,
        .layer_offset = layer_offset,
    };
}

/// Minimal CPAL v0 accessor — exposes the raw BGRA colour records of
/// palette 0. Higher palettes aren't supported yet because the
/// protocol doesn't carry a palette-selection channel.
pub const Cpal = struct {
    /// Palette 0's colour records, each 4 bytes: B, G, R, A.
    palette0: []const u8,
    /// Number of colour records in palette 0.
    num_entries: u16,

    pub const foreground_index: u16 = 0xFFFF;

    pub const Color = struct {
        /// sRGB BGRA channels. A==255 is fully opaque.
        r: u8,
        g: u8,
        b: u8,
        a: u8,
    };

    /// Resolve a palette index to a BGRA colour. Returns null for
    /// out-of-range indices. `0xFFFF` is the OpenType "use current
    /// foreground" sentinel — callers must handle it themselves; this
    /// function reports it as null so misuse is loud rather than
    /// silent-fallback.
    pub fn resolve(self: Cpal, index: u16) ?Color {
        if (index == foreground_index) return null;
        if (index >= self.num_entries) return null;
        const off: usize = @as(usize, index) * 4;
        if (off + 4 > self.palette0.len) return null;
        return .{
            .b = self.palette0[off],
            .g = self.palette0[off + 1],
            .r = self.palette0[off + 2],
            .a = self.palette0[off + 3],
        };
    }
};

/// Parse enough of CPAL to expose palette 0. Rejects files advertising
/// zero palettes or zero colour records.
pub fn parseCpal(cpal: []const u8) error{Malformed}!Cpal {
    if (cpal.len < 12) return error.Malformed;
    const version = readU16(cpal[0..2]);
    if (version > 1) return error.Malformed;
    const num_entries = readU16(cpal[2..4]);
    const num_palettes = readU16(cpal[4..6]);
    const num_color_records = readU16(cpal[6..8]);
    const colors_offset = readU32(cpal[8..12]);

    if (num_palettes == 0 or num_entries == 0 or num_color_records == 0) {
        return error.Malformed;
    }

    // `colorRecordIndices[0]` is the index (in colour records, not
    // bytes) of palette 0's first entry.
    if (14 > cpal.len) return error.Malformed;
    const first_color_index = readU16(cpal[12..14]);
    if (first_color_index + num_entries > num_color_records) return error.Malformed;

    const start = colors_offset + @as(usize, first_color_index) * 4;
    const end = start + @as(usize, num_entries) * 4;
    if (end > cpal.len) return error.Malformed;

    return .{
        .palette0 = cpal[start..end],
        .num_entries = num_entries,
    };
}

// -----------------------------------------------------------------------------
// internals

const Reader = struct {
    data: []const u8,
    pos: usize = 0,

    fn remaining(self: Reader) usize {
        return self.data.len - self.pos;
    }

    fn u16be(self: *Reader) error{Malformed}!u16 {
        if (self.remaining() < 2) return error.Malformed;
        const v = readU16(self.data[self.pos..][0..2]);
        self.pos += 2;
        return v;
    }

    fn bytes(self: *Reader, n: usize) error{Malformed}![]const u8 {
        if (self.remaining() < n) return error.Malformed;
        const out = self.data[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }
};

inline fn readU16(bytes: *const [2]u8) u16 {
    return (@as(u16, bytes[0]) << 8) | @as(u16, bytes[1]);
}

inline fn readU32(bytes: *const [4]u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

// -----------------------------------------------------------------------------
// tests

const testing = std.testing;

fn pushU16(buf: *std.ArrayList(u8), v: u16) !void {
    var a: [2]u8 = undefined;
    std.mem.writeInt(u16, &a, v, .big);
    try buf.appendSlice(testing.allocator, &a);
}

fn pushU32(buf: *std.ArrayList(u8), v: u32) !void {
    var a: [4]u8 = undefined;
    std.mem.writeInt(u32, &a, v, .big);
    try buf.appendSlice(testing.allocator, &a);
}

test "container parses two outlines + COLR + CPAL" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try pushU16(&buf, 2); // n_glyphs
    // glyph 0: 3 bytes
    try pushU16(&buf, 3);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0x01, 0x02, 0x03 });
    // glyph 1: 2 bytes
    try pushU16(&buf, 2);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0x0A, 0x0B });
    // colr: 5 bytes
    try pushU16(&buf, 5);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0xC0, 0xC1, 0xC2, 0xC3, 0xC4 });
    // cpal: 4 bytes
    try pushU16(&buf, 4);
    try buf.appendSlice(testing.allocator, &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE });

    var c = try parseContainer(testing.allocator, buf.items, .{ .cpal_required = true });
    defer c.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 2), c.outlines.len);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x01, 0x02, 0x03 }, c.outlines[0]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x0A, 0x0B }, c.outlines[1]);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xC0, 0xC1, 0xC2, 0xC3, 0xC4 }, c.colr);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xCA, 0xFE, 0xBA, 0xBE }, c.cpal);
}

test "container rejects zero n_glyphs" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 0);

    try testing.expectError(error.Malformed, parseContainer(
        testing.allocator,
        buf.items,
        .{ .cpal_required = true },
    ));
}

test "container rejects excess n_glyphs" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, max_outlines + 1);

    try testing.expectError(error.Malformed, parseContainer(
        testing.allocator,
        buf.items,
        .{ .cpal_required = true },
    ));
}

test "container rejects zero-length colr" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 1);
    try pushU16(&buf, 0); // glyph 0 of length 0 is fine
    try pushU16(&buf, 0); // colr_len = 0 is NOT fine
    try pushU16(&buf, 0);

    try testing.expectError(error.Malformed, parseContainer(
        testing.allocator,
        buf.items,
        .{ .cpal_required = false },
    ));
}

test "container rejects missing cpal when required" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 1);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xAA);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xBB);
    try pushU16(&buf, 0); // cpal_len = 0

    try testing.expectError(error.Malformed, parseContainer(
        testing.allocator,
        buf.items,
        .{ .cpal_required = true },
    ));
}

test "container allows missing cpal when optional (colrv1)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 1);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xAA);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xBB);
    try pushU16(&buf, 0); // cpal_len = 0 is OK for colrv1

    var c = try parseContainer(testing.allocator, buf.items, .{ .cpal_required = false });
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), c.cpal.len);
}

test "container rejects trailing bytes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 1);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xAA);
    try pushU16(&buf, 1);
    try buf.append(testing.allocator, 0xBB);
    try pushU16(&buf, 0);
    try buf.append(testing.allocator, 0x99); // garbage

    try testing.expectError(error.Malformed, parseContainer(
        testing.allocator,
        buf.items,
        .{ .cpal_required = false },
    ));
}

test "COLRv0 parses a two-layer base glyph" {
    // Hand-pack a COLR v0 table. Base glyph 0 → layers [0, 1]. Layer 0
    // uses glyphID 1 with palette 0; layer 1 uses glyphID 2 with
    // palette 1.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);

    try pushU16(&buf, 0); //  version
    try pushU16(&buf, 1); //  numBaseGlyphRecords
    try pushU32(&buf, 14); // baseGlyphRecordsOffset
    try pushU32(&buf, 14 + 6); // layerRecordsOffset (after 1 base rec)
    try pushU16(&buf, 2); //  numLayerRecords
    // base record 0: glyphID=0, firstLayerIndex=0, numLayers=2
    try pushU16(&buf, 0);
    try pushU16(&buf, 0);
    try pushU16(&buf, 2);
    // layer record 0: glyphID=1, paletteIndex=0
    try pushU16(&buf, 1);
    try pushU16(&buf, 0);
    // layer record 1: glyphID=2, paletteIndex=1
    try pushU16(&buf, 2);
    try pushU16(&buf, 1);

    const colr = try parseColrV0(buf.items);
    try testing.expectEqual(@as(u16, 1), colr.num_base_records);
    try testing.expectEqual(@as(u16, 2), colr.num_layer_records);

    const base = colr.findBaseGlyph(0).?;
    try testing.expectEqual(@as(u16, 2), base.num_layers);
    try testing.expectEqual(@as(u16, 0), base.first_layer_index);

    const l0 = try colr.layerAt(0);
    try testing.expectEqual(@as(u16, 1), l0.glyph_id);
    try testing.expectEqual(@as(u16, 0), l0.palette_index);
    const l1 = try colr.layerAt(1);
    try testing.expectEqual(@as(u16, 2), l1.glyph_id);
    try testing.expectEqual(@as(u16, 1), l1.palette_index);

    try testing.expect(colr.findBaseGlyph(99) == null);
}

test "COLR parser rejects versions beyond 1" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 2); // v2 doesn't exist in OpenType yet
    try buf.appendSlice(testing.allocator, &[_]u8{0} ** 12);
    try testing.expectError(error.Malformed, parseColrV0(buf.items));
}

test "COLR parser accepts version 1 (v1 = superset of v0 header)" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 1); // version 1
    try pushU16(&buf, 0); // numBase = 0
    try pushU32(&buf, 14); // baseOffset
    try pushU32(&buf, 14); // layerOffset
    try pushU16(&buf, 0); // numLayer

    const table = try parseColrV0(buf.items);
    try testing.expectEqual(@as(u16, 0), table.num_base_records);
}

test "CPAL parses single palette with two BGRA entries" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try pushU16(&buf, 0); // version
    try pushU16(&buf, 2); // numPaletteEntries
    try pushU16(&buf, 1); // numPalettes
    try pushU16(&buf, 2); // numColorRecords
    try pushU32(&buf, 14); // offsetFirstColorRecord (header ends at 14 = 12 + 2-byte colorRecordIndices[1])
    try pushU16(&buf, 0); // colorRecordIndices[0] = 0
    // Colour 0: BGRA 0x11,0x22,0x33,0xFF
    try buf.appendSlice(testing.allocator, &[_]u8{ 0x11, 0x22, 0x33, 0xFF });
    // Colour 1: BGRA 0xAA,0xBB,0xCC,0x80
    try buf.appendSlice(testing.allocator, &[_]u8{ 0xAA, 0xBB, 0xCC, 0x80 });

    const cpal = try parseCpal(buf.items);
    try testing.expectEqual(@as(u16, 2), cpal.num_entries);

    const c0 = cpal.resolve(0).?;
    try testing.expectEqual(@as(u8, 0x11), c0.b);
    try testing.expectEqual(@as(u8, 0x22), c0.g);
    try testing.expectEqual(@as(u8, 0x33), c0.r);
    try testing.expectEqual(@as(u8, 0xFF), c0.a);

    const c1 = cpal.resolve(1).?;
    try testing.expectEqual(@as(u8, 0xCC), c1.r);
    try testing.expectEqual(@as(u8, 0x80), c1.a);

    try testing.expect(cpal.resolve(2) == null);
    try testing.expect(cpal.resolve(Cpal.foreground_index) == null);
}
