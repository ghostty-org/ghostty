/// Glossary is the per-terminal storage for Glyph Protocol
/// codepoints. We use the word Glossary to match up with the spec which
/// also uses this word.
const Glossary = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const CircBuf = @import("../../../datastruct/circ_buf.zig").CircBuf;
const FontGlyph = @import("../../../font/Glyph.zig");
const Glyf = @import("../../../font/opentype/glyf.zig").Glyf;

const request = @import("request.zig");
const RegisterReq = request.Request.Register;

const DesignMetrics = FontGlyph.DesignMetrics;
const Constraint = FontGlyph.RenderOptions.Constraint;

/// Maximum entries allowed in the glossary before eviction.
/// Defined by the specification.
pub const max_entries = 1024;

/// An empty glossary with no registered glyphs.
pub const empty: Glossary = .{ .entries = .empty };

/// Errors that can occur while registering a glossary entry.
pub const RegisterError = Allocator.Error || error{OutOfNamespace};

/// Errors that can occur while clearing glossary entries.
pub const ClearError = error{OutOfNamespace};

/// The set of entries in the glossary keyed by the codepoint.
///
/// The array hash map preserves insertion order and has O(N)
/// orderedRemove, so we use it as a FIFO too for eviction when
/// the glossary is full. Since the specification limits the protocol
/// to 1024 maximum entries, ordered removal should never be that
/// expensive.
///
/// I'm also operating under the assumption that full glossaries
/// for a session will be rare, so the eviction cost shouldn't
/// happen regularly.
entries: std.AutoArrayHashMapUnmanaged(u21, Entry),

/// Release all glyph entries and hash map storage owned by the glossary.
pub fn deinit(self: *Glossary, alloc: Allocator) void {
    for (self.entries.values()) |*entry| entry.deinit(alloc);
    self.entries.deinit(alloc);
    self.* = undefined;
}

/// Register the given glyph entry.
///
/// This will act according to the glyph specification
pub fn register(
    self: *Glossary,
    alloc: Allocator,
    cp: u21,
    entry: Entry,
) RegisterError!void {
    // Validate codepoint according to spec.
    if (!isPrivateUse(cp)) return error.OutOfNamespace;

    const gop = try self.entries.getOrPut(alloc, cp);
    if (gop.found_existing) {
        // Found an existing entry, we need to shift the FIFO so
        // that this is now the most recent (at the end). This is
        // O(N) but N is usually small and max N is bounded by the spec.
        gop.value_ptr.*.deinit(alloc);
        assert(self.entries.orderedRemove(cp));

        // We already had enough capacity for this key before removing it, so
        // reinserting the replacement cannot require another allocation.
        self.entries.putAssumeCapacity(cp, entry);
        return;
    }

    // Array hash maps preserve insertion order so always immediately insert.
    gop.value_ptr.* = entry;

    // Fast, typical path: we fit within the glossary, just return.
    if (self.entries.count() <= max_entries) return;

    // Slow path: we need to evict.
    self.entries.values()[0].deinit(alloc);
    self.entries.orderedRemoveAt(0);
}

/// Delete a single entry from the glossary. If the entry doesn't exist,
/// then this does nothing and is safe.
pub fn delete(
    self: *Glossary,
    alloc: Allocator,
    cp: u21,
) ClearError!void {
    if (!isPrivateUse(cp)) return error.OutOfNamespace;
    const kv = self.entries.fetchOrderedRemove(cp) orelse return;
    var entry = kv.value;
    entry.deinit(alloc);
}

/// Clear all entries from the glossary and free up any underlying
/// storage.
pub fn clearAndFree(self: *Glossary, alloc: Allocator) void {
    for (self.entries.values()) |*entry| entry.deinit(alloc);
    self.entries.deinit(alloc);
    self.entries = .empty;
}

/// Contains returns true if the codepoint is covered by the glossary.
pub fn contains(self: *Glossary, cp: u21) bool {
    return self.entries.contains(cp);
}

/// A single glyph registration entry.
pub const Entry = struct {
    /// Stored glyph payload variants.
    pub const Glyph = union(enum) {
        glyf: Glyf.Outline,
    };

    /// The glyph itself. The tagged union only has glyf right now but
    /// will eventually expand to support COLR and maybe other formats.
    /// These are stored as raw outlines; rasterization is delayed to
    /// renderers. The outlines have been validated.
    glyph: Glyph,

    /// Authored metrics for the glyph's design coordinate space.
    design: DesignMetrics,

    /// Unicode cell width requested by the registration.
    width: request.Width,

    /// Normalized scale, alignment, and padding behavior for rasterization.
    constraint: Constraint,

    /// Errors that can occur while constructing a glossary entry from a
    /// register request.
    pub const InitError = RegisterReq.DecodeError || error{
        /// The register request is missing a required option or has an invalid
        /// explicitly-provided option value.
        InvalidOptions,

        /// The requested payload format is not supported by this glossary.
        UnsupportedFormat,
    };

    /// Initialize a glossary entry from a register request.
    ///
    /// This validates the request fields needed to construct the entry,
    /// decodes the base64 glyph payload, and stores the decoded outline. The
    /// returned entry owns decoded glyph memory and must be released with
    /// `deinit`.
    pub fn init(alloc: Allocator, req: RegisterReq) Entry.InitError!Entry {
        // Validate format
        const fmt = req.get(.fmt) orelse return error.InvalidOptions;
        const design: DesignMetrics = .{
            .units_per_em = req.get(.upm) orelse return error.InvalidOptions,
            .advance_width = req.get(.aw) orelse return error.InvalidOptions,
            .line_height = req.get(.lh) orelse return error.InvalidOptions,
        };
        if (design.units_per_em == 0 or
            design.advance_width == 0 or
            design.line_height == 0) return error.InvalidOptions;
        const width = req.get(.width) orelse return error.InvalidOptions;

        // Get our constraints
        const constraint = try constraintFromRegister(req);

        // Decode the payload into some usable glyph format for
        // future rasterization.
        const glyph: Glyph = switch (fmt) {
            .glyf => .{ .glyf = try req.decodeGlyfPayload(alloc) },
            .colrv0, .colrv1 => return error.UnsupportedFormat,
        };

        // No more errors, since we never do glyph cleanup above.
        errdefer comptime unreachable;

        return .{
            .glyph = glyph,
            .design = design,
            .width = width,
            .constraint = constraint,
        };
    }

    /// Release memory owned by this entry.
    pub fn deinit(self: *Entry, alloc: Allocator) void {
        switch (self.glyph) {
            .glyf => |*outline| outline.deinit(alloc),
        }
        self.* = undefined;
    }

    /// Return the renderer constraint for a register request.
    ///
    /// Glyph Protocol §8.5 defines sizing, alignment, and padding in terms of
    /// the authored extent and render span. This function is the single
    /// normalization point for how protocol sizing choices map to the
    /// renderer-neutral constraint stored here.
    fn constraintFromRegister(
        req: RegisterReq,
    ) error{InvalidOptions}!Constraint {
        // Register.get applies the Glyph Protocol §6.1 defaults when options
        // are omitted: size=height, align=center,center, and pad=0,0,0,0.
        const size = req.get(.size) orelse return error.InvalidOptions;
        const alignment = req.get(.@"align") orelse return error.InvalidOptions;
        const pad = req.get(.pad) orelse return error.InvalidOptions;

        return .{
            .size = switch (size) {
                // The rasterizer's base transform already maps the design em
                // to the cell height. That is the closest existing behavior to
                // the protocol's default height-driven mode.
                .height => .none,
                // There is no width-driven, aspect-preserving constraint mode
                // today. Leave the base transform intact rather than forcing a
                // fit/contain policy that would unexpectedly prevent overflow.
                .advance => .none,
                // Constraint.cover currently scales preserving aspect ratio to
                // the available bounds, which is the best existing match for
                // the protocol's contain mode.
                .contain => .cover,
                // There is no true protocol-cover equivalent that chooses the
                // larger axis scale, so use the nearest named renderer policy.
                .cover => .cover,
                .stretch => .stretch,
            },
            .align_horizontal = switch (alignment.horizontal) {
                .start => .start,
                .center => .center,
                .end => .end,
            },
            .align_vertical = switch (alignment.vertical) {
                .start => .start,
                .center => .center,
                .end => .end,
                // The current constraint API has no baseline alignment mode.
                // Start is the closest stable default because the glyf
                // rasterizer's coordinate model already treats y=0 as the
                // baseline/bottom before constraints are applied.
                .baseline => .start,
            },
            .pad_top = pad.top,
            .pad_right = pad.right,
            .pad_bottom = pad.bottom,
            .pad_left = pad.left,
        };
    }
};

/// Return true if `cp` is in one of the Unicode Private Use Areas.
fn isPrivateUse(cp: u21) bool {
    return (cp >= 0xE000 and cp <= 0xF8FF) or
        (cp >= 0xF0000 and cp <= 0xFFFFD) or
        (cp >= 0x100000 and cp <= 0x10FFFD);
}

fn testParseRegister(alloc: Allocator, data: []const u8) !RegisterReq {
    const raw = try alloc.dupe(u8, data);
    errdefer alloc.free(raw);

    const req = try request.Request.parse(alloc, raw);
    switch (req) {
        .register => |reg| return reg,
        else => unreachable,
    }
}

// Base64-encoded glyf payload from the "glyf: decode triangle" test in
// font/opentype/glyf.zig. This is a real simple-glyph record with one contour
// and three on-curve points.
const test_triangle_glyf_payload = "AAEAZABkA4QDhAACAAABAQEB9P5wAyADhPzgAAA=";

fn testRegisterReq(alloc: Allocator, cp: u21) !RegisterReq {
    const data = try std.fmt.allocPrint(
        alloc,
        "r;cp={x};upm=2048;aw=1024;lh=1536;width=2;size=stretch;align=end,start;pad=0.1,0.2,0.3,0.4;{s}",
        .{ cp, test_triangle_glyf_payload },
    );
    errdefer alloc.free(data);

    const req = try request.Request.parse(alloc, data);
    switch (req) {
        .register => |reg| return reg,
        else => unreachable,
    }
}

fn testRegisterEntry(alloc: Allocator, cp: u21) !Entry {
    const req = try testRegisterReq(alloc, cp);
    defer alloc.free(req.raw);
    return try Entry.init(alloc, req);
}

test "Entry init decodes glyf payload and applies register fields" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const req = try testRegisterReq(alloc, 0xE000);
    defer alloc.free(req.raw);

    var entry = try Entry.init(alloc, req);
    defer entry.deinit(alloc);

    try testing.expectEqual(@as(u32, 2048), entry.design.units_per_em);
    try testing.expectEqual(@as(u32, 1024), entry.design.advance_width);
    try testing.expectEqual(@as(u32, 1536), entry.design.line_height);
    try testing.expectEqual(request.Width.wide, entry.width);
    try testing.expectEqual(Constraint.Size.stretch, entry.constraint.size);
    try testing.expectEqual(Constraint.Align.end, entry.constraint.align_horizontal);
    try testing.expectEqual(Constraint.Align.start, entry.constraint.align_vertical);
    try testing.expectEqual(@as(f64, 0.1), entry.constraint.pad_top);
    try testing.expectEqual(@as(f64, 0.2), entry.constraint.pad_right);
    try testing.expectEqual(@as(f64, 0.3), entry.constraint.pad_bottom);
    try testing.expectEqual(@as(f64, 0.4), entry.constraint.pad_left);

    try testing.expectEqual(@as(usize, 3), entry.glyph.glyf.points.len);
    try testing.expectEqual(@as(usize, 1), entry.glyph.glyf.contours.len);
}

test "Entry init rejects invalid register payload" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const req = try testParseRegister(alloc, "r;cp=e000;%%%not-base64%%%");
    defer alloc.free(req.raw);

    try testing.expectError(error.MalformedPayload, Entry.init(alloc, req));
}

test "Glossary register overwrites and moves entry to newest position" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));
    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));

    try testing.expectEqual(@as(usize, 2), glossary.entries.count());
    try testing.expectEqual(@as(u21, 0xE001), glossary.entries.keys()[0]);
    try testing.expectEqual(@as(u21, 0xE000), glossary.entries.keys()[1]);
}

test "Glossary register evicts oldest entry" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    for (0..max_entries + 1) |i| {
        const cp: u21 = @intCast(0xE000 + i);
        try glossary.register(alloc, cp, try testRegisterEntry(alloc, cp));
    }

    try testing.expectEqual(@as(usize, max_entries), glossary.entries.count());
    try testing.expect(!glossary.entries.contains(0xE000));
    try testing.expect(glossary.entries.contains(0xE001));
    try testing.expect(glossary.entries.contains(0xE000 + max_entries));
}

test "Glossary register rejects non-PUA codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    var entry = try testRegisterEntry(alloc, 0xE000);
    defer entry.deinit(alloc);
    try testing.expectError(error.OutOfNamespace, glossary.register(alloc, 'A', entry));
}

test "Glossary delete removes one PUA slot and ignores empty PUA slot" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));

    try glossary.delete(alloc, 0xE000);
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(!glossary.contains(0xE000));
    try testing.expect(glossary.contains(0xE001));

    try glossary.delete(alloc, 0xE000);
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE001));
}

test "Glossary delete rejects non-PUA codepoint" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try testing.expectError(error.OutOfNamespace, glossary.delete(alloc, 'A'));
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE000));
}

test "Glossary clearAndFree removes all slots and remains reusable" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try glossary.register(alloc, 0xE001, try testRegisterEntry(alloc, 0xE001));

    glossary.clearAndFree(alloc);
    try testing.expectEqual(@as(usize, 0), glossary.entries.count());
    try testing.expect(!glossary.contains(0xE000));
    try testing.expect(!glossary.contains(0xE001));

    try glossary.register(alloc, 0xE002, try testRegisterEntry(alloc, 0xE002));
    try testing.expectEqual(@as(usize, 1), glossary.entries.count());
    try testing.expect(glossary.contains(0xE002));
}

test "Glossary contains reports registered slots" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);

    try testing.expect(!glossary.contains(0xE000));

    try glossary.register(alloc, 0xE000, try testRegisterEntry(alloc, 0xE000));
    try testing.expect(glossary.contains(0xE000));
    try testing.expect(!glossary.contains(0xE001));
}
