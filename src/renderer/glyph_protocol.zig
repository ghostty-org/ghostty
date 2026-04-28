//! Renderer-side bridge for the Glyph Protocol.
//!
//! Every frame the renderer takes a snapshot of the terminal's session
//! glossary under the terminal mutex (`syncFrom`), cloning each
//! registration's payload (glyf outline or colr container) into
//! renderer-owned storage so later calls on the render thread can
//! touch the clones without locking.
//!
//! At cell-emission time the renderer asks `resolve` for the atlas
//! entry of a registered codepoint at a specific cell size. On cache
//! miss this rasterizes the payload via `font.glyph_protocol_raster`
//! and uploads the bitmap into the appropriate atlas — grayscale for
//! `glyf`, colour (BGRA) for `colrv0`/`colrv1`. The bitmap cache is
//! keyed on `(codepoint, generation, cell size)` so an overwrite or
//! clear invalidates the stale entry exactly when the glossary mutates.

const std = @import("std");
const Allocator = std.mem.Allocator;

const font = @import("../font/main.zig");
const terminal = @import("../terminal/main.zig");
const raster = font.glyph_protocol_raster;
const glyf = terminal.apc.glyph.glyf;
const colr = terminal.apc.glyph.request.colr;
const Glossary = terminal.apc.glyph.Glossary;

pub const State = struct {
    alloc: Allocator,

    /// Cloned payloads from the terminal's glossary, keyed by
    /// codepoint. Populated under the terminal mutex in `syncFrom`;
    /// read lock-free from the render thread afterwards.
    payloads: std.AutoHashMapUnmanaged(u21, Clone) = .empty,

    /// Rasterized atlas entries cached across frames.
    bitmaps: std.AutoHashMapUnmanaged(BitmapKey, CachedGlyph) = .empty,

    /// Last-seen `Glossary.mutation_count`. When the current value
    /// differs, payloads and bitmaps are resynced on the next call
    /// to `syncFrom`.
    last_mutation: u64 = 0,

    /// True once `syncFrom` has been called at least once. Lets the
    /// initial sync run even when a freshly-initialized glossary has
    /// `mutation_count == 0`.
    initialized: bool = false,

    /// Cloned form of one registration. Tagged by payload kind so
    /// `resolve` picks the right rasterizer and atlas.
    pub const Clone = struct {
        payload: ClonedPayload,
        upm: u16,
        generation: u64,
    };

    pub const ClonedPayload = union(enum) {
        glyf: glyf.Outline,
        colrv0: colr.Container,
        colrv1: colr.Container,

        pub fn deinit(self: *ClonedPayload, alloc: Allocator) void {
            switch (self.*) {
                .glyf => |*o| o.deinit(alloc),
                .colrv0, .colrv1 => |*c| c.deinit(alloc),
            }
        }
    };

    pub const BitmapKey = struct {
        cp: u21,
        generation: u64,
        cell_w: u16,
        cell_h: u16,
    };

    /// Resolved atlas entry: tells the caller which atlas (grayscale
    /// or colour) the glyph was placed in.
    pub const CachedGlyph = struct {
        glyph: font.Glyph,
        atlas: Atlas,
    };

    pub const Atlas = enum { grayscale, color };

    pub fn init(alloc: Allocator) State {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *State) void {
        self.clearPayloads();
        self.payloads.deinit(self.alloc);
        self.bitmaps.deinit(self.alloc);
        self.* = undefined;
    }

    fn clearPayloads(self: *State) void {
        var it = self.payloads.valueIterator();
        while (it.next()) |c| c.payload.deinit(self.alloc);
        self.payloads.clearRetainingCapacity();
    }

    /// Must be called while the caller holds the terminal state mutex,
    /// because it reads the glossary's live entries. If the glossary
    /// has mutated since the last call, every payload is recloned and
    /// the bitmap cache is fully invalidated.
    pub fn syncFrom(self: *State, glossary: *const Glossary) Allocator.Error!void {
        if (self.initialized and glossary.mutation_count == self.last_mutation) return;

        self.clearPayloads();
        self.bitmaps.clearRetainingCapacity();

        try self.payloads.ensureTotalCapacity(
            self.alloc,
            @intCast(glossary.by_cp.count()),
        );

        var it = glossary.by_cp.iterator();
        while (it.next()) |kv| {
            const cp = kv.key_ptr.*;
            const entry = kv.value_ptr;
            const cloned = try clonePayload(self.alloc, entry.payload);
            self.payloads.putAssumeCapacity(cp, .{
                .payload = cloned,
                .upm = entry.upm,
                .generation = entry.generation,
            });
        }

        self.last_mutation = glossary.mutation_count;
        self.initialized = true;
    }

    /// Return the cached atlas entry for a registered codepoint at the
    /// requested cell size, rasterizing on cache miss. Returns `null`
    /// when the codepoint is not registered, so callers can fall
    /// through to the normal font lookup. `foreground` is the cell's
    /// current text colour; it's routed to CPAL palette index `0xFFFF`
    /// (the OpenType "use foreground" sentinel) and to v1's solid
    /// foreground paints.
    pub fn resolve(
        self: *State,
        cp: u21,
        cell_w: u16,
        cell_h: u16,
        foreground: raster.Rgba,
        grayscale_atlas: *font.Atlas,
        color_atlas: *font.Atlas,
        atlas_lock: *std.Thread.RwLock,
    ) ResolveError!?CachedGlyph {
        // Silent miss — misses are frequent (every non-PUA cell in the
        // viewport hits this path), so only log hits to keep the debug
        // stream readable during the empty-image investigation.
        const clone = self.payloads.getPtr(cp) orelse return null;
        const key: BitmapKey = .{
            .cp = cp,
            .generation = clone.generation,
            .cell_w = cell_w,
            .cell_h = cell_h,
        };
        if (self.bitmaps.get(key)) |g| return g;

        const cached = switch (clone.payload) {
            .glyf => |outline| try rasterizeGlyf(
                self.alloc,
                outline,
                clone.upm,
                cell_w,
                cell_h,
                grayscale_atlas,
                atlas_lock,
            ),
            .colrv0 => |container| try rasterizeColor(
                self.alloc,
                container,
                clone.upm,
                cell_w,
                cell_h,
                foreground,
                .v0,
                color_atlas,
                atlas_lock,
            ),
            .colrv1 => |container| try rasterizeColor(
                self.alloc,
                container,
                clone.upm,
                cell_w,
                cell_h,
                foreground,
                .v1,
                color_atlas,
                atlas_lock,
            ),
        };

        try self.bitmaps.put(self.alloc, key, cached);
        return cached;
    }
};

pub const ResolveError = Allocator.Error || raster.ColorError || font.Atlas.Error;

fn rasterizeGlyf(
    alloc: Allocator,
    outline: glyf.Outline,
    upm: u16,
    cell_w: u16,
    cell_h: u16,
    atlas: *font.Atlas,
    atlas_lock: *std.Thread.RwLock,
) !State.CachedGlyph {
    var bitmap = try raster.rasterize(alloc, outline, upm, cell_w, cell_h);
    defer bitmap.deinit(alloc);

    atlas_lock.lock();
    defer atlas_lock.unlock();

    const region = try atlas.reserve(alloc, bitmap.width, bitmap.height);
    atlas.set(region, bitmap.data);

    return .{
        .glyph = .{
            .width = bitmap.width,
            .height = bitmap.height,
            .offset_x = 0,
            .offset_y = @intCast(bitmap.height),
            .atlas_x = region.x,
            .atlas_y = region.y,
        },
        .atlas = .grayscale,
    };
}

fn rasterizeColor(
    alloc: Allocator,
    container: colr.Container,
    upm: u16,
    cell_w: u16,
    cell_h: u16,
    foreground: raster.Rgba,
    version: enum { v0, v1 },
    atlas: *font.Atlas,
    atlas_lock: *std.Thread.RwLock,
) !State.CachedGlyph {
    var bitmap = switch (version) {
        .v0 => try raster.rasterizeColrV0(alloc, container, upm, cell_w, cell_h, foreground),
        .v1 => try raster.rasterizeColrV1(alloc, container, upm, cell_w, cell_h, foreground),
    };
    defer bitmap.deinit(alloc);

    atlas_lock.lock();
    defer atlas_lock.unlock();

    const region = try atlas.reserve(alloc, bitmap.width, bitmap.height);
    atlas.set(region, bitmap.data);

    return .{
        .glyph = .{
            .width = bitmap.width,
            .height = bitmap.height,
            .offset_x = 0,
            .offset_y = @intCast(bitmap.height),
            .atlas_x = region.x,
            .atlas_y = region.y,
        },
        .atlas = .color,
    };
}

fn clonePayload(
    alloc: Allocator,
    src: terminal.apc.glyph.request.DecodedPayload,
) Allocator.Error!State.ClonedPayload {
    return switch (src) {
        .glyf => |o| .{ .glyf = try cloneOutline(alloc, o) },
        .colrv0 => |c| .{ .colrv0 = try cloneContainer(alloc, c) },
        .colrv1 => |c| .{ .colrv1 = try cloneContainer(alloc, c) },
    };
}

/// Deep-copy an `Outline` into renderer-owned storage. The source's
/// `contours` slices into its `points`; the copy preserves that
/// relationship by remapping offsets into the fresh points buffer.
fn cloneOutline(alloc: Allocator, src: glyf.Outline) Allocator.Error!glyf.Outline {
    if (src.points.len == 0) {
        return .{
            .contours = &.{},
            .points = &.{},
            .x_min = src.x_min,
            .y_min = src.y_min,
            .x_max = src.x_max,
            .y_max = src.y_max,
        };
    }

    const points = try alloc.alloc(glyf.Point, src.points.len);
    errdefer alloc.free(points);
    @memcpy(points, src.points);

    const contours = try alloc.alloc([]glyf.Point, src.contours.len);
    errdefer alloc.free(contours);

    const base: usize = @intFromPtr(src.points.ptr);
    for (src.contours, 0..) |c, i| {
        const offset = (@intFromPtr(c.ptr) - base) / @sizeOf(glyf.Point);
        contours[i] = points[offset .. offset + c.len];
    }

    return .{
        .contours = contours,
        .points = points,
        .x_min = src.x_min,
        .y_min = src.y_min,
        .x_max = src.x_max,
        .y_max = src.y_max,
    };
}

fn cloneContainer(alloc: Allocator, src: colr.Container) Allocator.Error!colr.Container {
    const outlines = try alloc.alloc([]u8, src.outlines.len);
    var allocated: usize = 0;
    errdefer {
        for (outlines[0..allocated]) |o| alloc.free(o);
        alloc.free(outlines);
    }
    for (src.outlines, 0..) |o, i| {
        outlines[i] = try alloc.dupe(u8, o);
        allocated += 1;
    }

    const colr_bytes = try alloc.dupe(u8, src.colr);
    errdefer alloc.free(colr_bytes);
    const cpal_bytes = try alloc.dupe(u8, src.cpal);
    errdefer alloc.free(cpal_bytes);

    return .{ .outlines = outlines, .colr = colr_bytes, .cpal = cpal_bytes };
}
