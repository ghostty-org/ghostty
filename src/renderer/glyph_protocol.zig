const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;

const font = @import("../font/main.zig");
const glyf_rasterize = font.glyf_rasterize;
const Glossary = @import("../terminal/main.zig").apc.glyph.Glossary;
const Glyf = @import("../font/opentype/glyf.zig").Glyf;

/// Map of registered codepoints in renderer-local state.
pub const CodepointMap = std.AutoArrayHashMapUnmanaged(u21, Codepoint);

/// Renderer-local Glyph Protocol state for one terminal session.
///
/// The terminal owns the authoritative `Glossary`, but the renderer cannot
/// keep pointers into it because rendering happens outside the terminal mutex
/// and rasterized atlas metadata has renderer-specific lifetime.
///
/// This state is a snapshot of the terminal glossary plus lazy rasterization
/// cache for glyphs that have actually appeared on screen.
pub const State = struct {
    /// Registered codepoints keyed by Unicode scalar value.
    codepoints: CodepointMap = .empty,

    /// Empty initial state with no registrations and no allocated storage.
    pub const empty: State = .{ .codepoints = .empty };

    /// Release all cloned glossary entries and map storage owned by this state.
    pub fn deinit(self: *State, alloc: Allocator) void {
        for (self.codepoints.values()) |*entry| entry.deinit(alloc);
        self.codepoints.deinit(alloc);
        self.* = undefined;
    }

    /// Synchronize the renderer-local state from the terminal glossary.
    ///
    /// This does a full replacement rather than attempting to diff because the
    /// glossary is spec-limited to 1024 entries and full replacement naturally
    /// invalidates rasterized glyphs for clear, overwrite, and FIFO eviction.
    /// If cloning fails, the previous renderer state is left intact.
    pub fn syncFromGlossary(
        self: *State,
        alloc: Allocator,
        glossary: *const Glossary,
    ) Allocator.Error!void {
        // Build a complete replacement first. If any clone/allocation fails,
        // errdefer releases the partial map and `self` continues to point at
        // the previous successfully-synced snapshot.
        var new_codepoints: CodepointMap = .empty;
        errdefer deinitMap(&new_codepoints, alloc);

        try new_codepoints.ensureTotalCapacity(alloc, glossary.entries.count());
        for (glossary.entries.keys(), glossary.entries.values()) |cp, *entry| {
            new_codepoints.putAssumeCapacityNoClobber(cp, .{
                .entry = try entry.clone(alloc),
            });
        }

        // Only after the new snapshot is complete do we release the old one.
        // This makes sync failure non-destructive, which lets the renderer
        // fall back to the last good snapshot under memory pressure.
        deinitMap(&self.codepoints, alloc);
        self.codepoints = new_codepoints;
    }

    /// Invalidate rasterized atlas metadata while preserving registration
    /// entries so they can be re-rasterized for a new font grid or cell size.
    ///
    /// Call this when the terminal grid metrics change in any way.
    pub fn invalidateRasterized(self: *State) void {
        for (self.codepoints.values()) |*entry| entry.rasterized = null;
    }

    /// Errors that callers of `renderGlyph` can meaningfully react to.
    pub const RenderError = Allocator.Error || error{
        /// The decoded glyph could not be rasterized by the renderer.
        RasterizationFailed,
    };

    /// Render a registered codepoint into the shared grayscale atlas, lazily.
    ///
    /// The returned glyph is atlas metadata only. The underlying registration
    /// entry is kept so font-grid changes can invalidate and rasterize again.
    pub fn renderGlyph(
        self: *State,
        alloc: Allocator,
        grid: *font.SharedGrid,
        grid_metrics: font.Metrics,
        cp: u21,
    ) RenderError!?font.Glyph {
        const codepoint = self.codepoints.getPtr(cp) orelse return null;

        // Fast path: the glyph was already rasterized into the current font
        // atlas. `font.Glyph` is just atlas metadata, so returning it by value
        // is cheap and avoids touching the cloned outline again.
        if (codepoint.rasterized) |glyph| return glyph;

        const entry = &codepoint.entry;

        // Glyph Protocol `width` is the requested cell span. Use it for both
        // the bitmap width and constraint span so sizing/alignment/padding are
        // applied over the same 1- or 2-cell render span described by the spec.
        const width_cells: u2 = switch (entry.width) {
            .narrow => 1,
            .wide => 2,
        };

        // Decode-time validation already guaranteed this is a supported glyf
        // outline. Rasterization happens lazily because applications may
        // register many glyphs that never become visible.
        var bitmap = switch (entry.glyph) {
            .glyf => |outline| glyf_rasterize.rasterize(
                alloc,
                outline,
                entry.design,
                .{
                    .grid_metrics = grid_metrics,
                    .cell_width = width_cells,
                    .constraint = entry.constraint,
                    .constraint_width = width_cells,
                },
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,

                error.NoCurrentPoint,
                error.InvalidMatrix,
                error.PathNotClosed,
                error.InvalidHeight,
                error.InvalidWidth,
                error.InvalidState,
                => return error.RasterizationFailed,
            },
        };
        defer bitmap.deinit(alloc);

        // Cache the empty result too. This prevents repeated rasterization for
        // valid but visually-empty outlines while keeping downstream render code
        // on the normal zero-sized-glyph skip path.
        if (bitmap.width == 0 or bitmap.height == 0) {
            codepoint.rasterized = .{
                .width = 0,
                .height = 0,
                .offset_x = 0,
                .offset_y = 0,
                .atlas_x = 0,
                .atlas_y = 0,
            };
            return codepoint.rasterized.?;
        }

        // Atlas allocation and writes must hold the shared grid lock. The more
        // expensive vector rasterization above intentionally happens outside the
        // lock so other surfaces sharing this grid are blocked for less time.
        grid.lock.lock();
        defer grid.lock.unlock();

        // Reuse the normal font grayscale atlas. If it fills up, grow it and
        // retry just like SharedGrid.renderGlyph does for regular font glyphs.
        const region = region: while (true) {
            break :region grid.atlas_grayscale.reserve(
                alloc,
                bitmap.width,
                bitmap.height,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.AtlasFull => {
                    try grid.atlas_grayscale.grow(alloc, grid.atlas_grayscale.size * 2);
                    continue;
                },
            };
        };
        grid.atlas_grayscale.set(region, bitmap.data);

        // A Glyph Protocol glyf bitmap is rasterized as a full render-span
        // bitmap. A top bearing equal to bitmap height places the top of the
        // quad at the top of the cell in the existing text shader convention.
        codepoint.rasterized = .{
            .width = bitmap.width,
            .height = bitmap.height,
            .offset_x = 0,
            .offset_y = @intCast(bitmap.height),
            .atlas_x = region.x,
            .atlas_y = region.y,
        };

        return codepoint.rasterized.?;
    }

    /// Release a codepoint map and all cloned entries in it.
    ///
    /// This helper resets the map to `.empty` so it can be safely reused after
    /// both successful replacement and error-path cleanup.
    fn deinitMap(map: *CodepointMap, alloc: Allocator) void {
        for (map.values()) |*entry| entry.deinit(alloc);
        map.deinit(alloc);
        map.* = .empty;
    }
};

/// One registered codepoint in the renderer snapshot.
pub const Codepoint = struct {
    /// Cloned terminal glossary entry. This is kept even after rasterization so
    /// font grid changes can discard atlas metadata and rasterize again.
    entry: Glossary.Entry,

    /// Cached atlas metadata for the current font grid, if visible before.
    rasterized: ?font.Glyph = null,

    /// Release the cloned glossary entry owned by this codepoint.
    pub fn deinit(self: *Codepoint, alloc: Allocator) void {
        self.entry.deinit(alloc);
        self.* = undefined;
    }
};

fn testEntry(alloc: Allocator, x_offset: i32) !Glossary.Entry {
    const contours = try alloc.dupe(u16, &.{2});
    errdefer alloc.free(contours);

    const points = try alloc.dupe(Glyf.Outline.Point, &.{
        .{ .x = x_offset, .y = 0, .on_curve = true },
        .{ .x = x_offset + 500, .y = 0, .on_curve = true },
        .{ .x = x_offset, .y = 500, .on_curve = true },
    });
    errdefer alloc.free(points);

    return .{
        .glyph = .{ .glyf = .{
            .contours = contours,
            .points = points,
        } },
        .design = .{
            .units_per_em = 1000,
            .advance_width = 1000,
            .line_height = 1000,
        },
        .width = .narrow,
        .constraint = .none,
    };
}

test "State syncFromGlossary clones terminal entries" {
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testEntry(alloc, 0));

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.syncFromGlossary(alloc, &glossary);

    try testing.expect(state.codepoints.contains(0xE000));
    try testing.expect(!state.codepoints.contains(0xE001));

    const src = glossary.entries.getPtr(0xE000).?;
    const dst = state.codepoints.getPtr(0xE000).?;
    try testing.expect(src.glyph.glyf.points.ptr != dst.entry.glyph.glyf.points.ptr);
    try testing.expectEqual(src.glyph.glyf.points[0], dst.entry.glyph.glyf.points[0]);
}

test "State syncFromGlossary replaces removed and changed entries" {
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testEntry(alloc, 0));

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.syncFromGlossary(alloc, &glossary);

    try glossary.register(alloc, 0xE001, try testEntry(alloc, 10));
    try glossary.delete(alloc, 0xE000);
    try state.syncFromGlossary(alloc, &glossary);

    try testing.expect(!state.codepoints.contains(0xE000));
    try testing.expect(state.codepoints.contains(0xE001));
    try testing.expectEqual(@as(i32, 10), state.codepoints.getPtr(0xE001).?.entry.glyph.glyf.points[0].x);
}

test "State invalidateRasterized clears cached glyph metadata" {
    const alloc = testing.allocator;

    var glossary: Glossary = .empty;
    defer glossary.deinit(alloc);
    try glossary.register(alloc, 0xE000, try testEntry(alloc, 0));

    var state: State = .empty;
    defer state.deinit(alloc);
    try state.syncFromGlossary(alloc, &glossary);

    const codepoint = state.codepoints.getPtr(0xE000).?;
    codepoint.rasterized = .{
        .width = 1,
        .height = 1,
        .offset_x = 0,
        .offset_y = 1,
        .atlas_x = 2,
        .atlas_y = 3,
    };

    state.invalidateRasterized();
    try testing.expect(codepoint.rasterized == null);
}

test "State renderGlyph returns null for unregistered codepoint" {
    var state: State = .empty;

    const grid: *font.SharedGrid = undefined;
    const glyph = try state.renderGlyph(
        testing.allocator,
        grid,
        undefined,
        0xE000,
    );
    try testing.expect(glyph == null);
}
