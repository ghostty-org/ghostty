const std = @import("std");
const assert = @import("../../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

const terminal = @import("../main.zig");
const point = @import("../point.zig");
const size = @import("../size.zig");
const animation = @import("graphics_animation.zig");
const pixel = @import("graphics_pixel.zig");
const command = @import("graphics_command.zig");
const PageList = @import("../PageList.zig");
const Screen = @import("../Screen.zig");
const LoadingImage = @import("graphics_image.zig").LoadingImage;
const Image = @import("graphics_image.zig").Image;
const Rect = @import("graphics_image.zig").Rect;
const Command = command.Command;

const log = std.log.scoped(.kitty_gfx);

/// Process-global counter backing all generation stamps (see
/// ImageStorage.generation and Image.generation). This is global rather
/// than per-storage so that stamps are unique across every storage in
/// the process: two mutation events never produce the same value, even
/// across separate screens (main vs. alt), storage resets, or separate
/// terminals. This lets consumers use a generation value alone as a
/// cache key without any ambiguity.
///
/// Thread-safe because separate terminals may mutate their storages
/// from different threads. On single-threaded targets this lowers to
/// plain operations.
var generation_counter: GenerationCounter = .{};

/// Returns the next generation stamp. Stamps are unique and strictly
/// monotonically increasing process-wide, starting at 1 (0 is reserved
/// to mean "never stamped").
pub fn nextGeneration(io: std.Io) u64 {
    return generation_counter.next(io);
}

/// Backing implementation for the generation counter. We use a
/// lock-free atomic counter where we can, but not all targets support
/// 64-bit atomic operations (e.g. 32-bit ARM Android), so we fall back
/// to a mutex-protected counter on those. This is a cold path (only
/// invoked on content mutations) so the mutex cost is irrelevant.
///
/// The pointer-width check is a conservative proxy for 64-bit atomic
/// support: every 64-bit target supports 64-bit atomics, while 32-bit
/// targets may not (per the compiler's atomic operand validation).
const GenerationCounter = if (@bitSizeOf(usize) >= 64) struct {
    value: std.atomic.Value(u64) = .init(0),

    fn next(self: *@This(), io: std.Io) u64 {
        _ = io;
        return self.value.fetchAdd(1, .monotonic) + 1;
    }
} else struct {
    mutex: std.Io.Mutex = .init,
    value: u64 = 0,

    fn next(self: *@This(), io: std.Io) u64 {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value += 1;
        return self.value;
    }
};

/// An image storage is associated with a terminal screen (i.e. main
/// screen, alt screen) and contains all the transmitted images and
/// placements.
pub const ImageStorage = struct {
    const ImageMap = std.AutoHashMapUnmanaged(u32, Image);
    const PlacementMap = std.AutoHashMapUnmanaged(PlacementKey, Placement);

    /// Dirty is set to true if placements or images change. This is
    /// purely informational for the renderer and doesn't affect the
    /// correctness of the program. The renderer must set this to false
    /// if it cares about this value.
    ///
    /// Note that dirty is also set by scrolling and resizing (outside
    /// of this struct) because those move placement pins, even though
    /// the set of images/placements itself is unchanged. See generation
    /// for a signal that only tracks content mutations.
    ///
    /// Invariant: dirty is always set when generation changes
    /// (markMutated sets both); dirty set without a generation change
    /// means a geometry-only event.
    dirty: bool = false,

    /// Generation stamp of the last content mutation to this storage:
    /// any image transmit/replace, placement add, or delete of either.
    /// Zero means the storage has never been mutated (and is therefore
    /// empty).
    ///
    /// Unlike dirty, this is NOT updated by scrolling/resizing, so an
    /// unchanged generation means the placement set and all image data
    /// are identical; only placement geometry (pins) may have moved.
    /// Values come from a process-global monotonic counter, so a value
    /// observed from any storage never recurs for different content,
    /// even across screen switches or storage resets.
    ///
    /// This field must only be written via markMutated.
    generation: u64 = 0,

    /// This is the next automatically assigned image ID for images
    /// transmitted without an ID or number. We start mid-way through
    /// the u32 range to stay clear of the low IDs client programs
    /// typically pick. See nextImageId.
    next_image_id: u32 = 2147483647,

    /// This is the next automatically assigned placement ID. This is never
    /// user-facing so we can start at 0. This is 32-bits because we use
    /// the same space for external placement IDs. We can start at zero
    /// because any number is valid.
    next_internal_placement_id: u32 = 0,

    /// The set of images that are currently known.
    images: ImageMap = .{},

    /// The set of placements for loaded images.
    placements: PlacementMap = .{},

    /// Non-null if there is an in-progress loading image.
    loading: ?*LoadingImage = null,

    /// The limits of what medium types are allowed for image loading.
    image_limits: LoadingImage.Limits = .direct,

    /// The total bytes of image data that have been loaded and the limit.
    /// If the limit is reached, the oldest images will be evicted to make
    /// space. Unused images take priority.
    total_bytes: usize = 0,
    total_limit: usize = 320 * 1000 * 1000, // 320MB

    /// Identifies one exact pending image transmission. The generation is
    /// assigned by this storage when the pending image is inserted, so a
    /// later replacement of the same ID cannot consume stale payload bytes.
    pub const PendingImage = struct {
        id: u32,
        generation: u64,

        /// Attach owned decoded bytes if this exact pending transmission is
        /// still resident. On true, storage owns `data`; on false, the caller
        /// retains ownership. Completion preserves the image generation (and
        /// therefore eviction age) while marking storage content as mutated.
        pub fn complete(
            self: PendingImage,
            storage: *ImageStorage,
            io: std.Io,
            data: []const u8,
        ) bool {
            const img = storage.images.getPtr(self.id) orelse return false;
            if (img.generation != self.generation) return false;

            const expected_len = switch (img.data) {
                .complete => return false,
                .pending => |len| len,
            };
            if (data.len != expected_len) return false;

            img.data = .{ .complete = data };
            storage.markMutated(io);
            return true;
        }
    };

    pub fn deinit(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
    ) void {
        if (self.loading) |loading| loading.destroy(alloc);

        self.clearPlacements(s);
        self.placements.deinit(alloc);

        var it = self.images.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(alloc);
        self.images.deinit(alloc);
    }

    /// Kitty image protocol is enabled if we have a non-zero limit.
    pub fn enabled(self: *const ImageStorage) bool {
        return self.total_limit != 0;
    }

    /// Record a content mutation: marks the storage dirty and assigns a
    /// fresh generation stamp. Must be called by anything that changes
    /// the set of images or placements (or image contents), including
    /// the animation command handlers in graphics_exec.zig.
    ///
    /// Do NOT call this for geometry-only events (scrolling, resizing,
    /// screen switches); those must set only the dirty flag directly.
    /// Bumping the generation for geometry changes would break the
    /// contract that an unchanged generation means unchanged contents.
    pub fn markMutated(self: *ImageStorage, io: std.Io) void {
        self.dirty = true;
        self.generation = nextGeneration(io);
    }

    /// Sets the limit in bytes for the total amount of image data that
    /// can be loaded. If this limit is lower, this will do an eviction
    /// if necessary. If the value is zero, then Kitty image protocol will
    /// be disabled.
    pub fn setLimit(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        limit: usize,
    ) void {
        // Special case disabling by quickly deleting all
        if (limit == 0) {
            const image_limits = self.image_limits;
            self.deinit(alloc, s);
            self.* = .{ .image_limits = image_limits };
            self.markMutated(io);
        }

        // If we re lowering our limit, check if we need to evict.
        if (limit < self.total_bytes) {
            const req_bytes = self.total_bytes - limit;
            log.info("evicting images to lower limit, evicting={}", .{req_bytes});
            if (!self.evictImage(io, alloc, s, req_bytes)) {
                log.warn("failed to evict enough images for required bytes", .{});
            }
        }

        self.total_limit = limit;
    }

    /// Returns the next ID to automatically assign to an image that
    /// was transmitted without an explicit ID (i=). The result is
    /// never zero (zero means "no ID") and never an ID currently in
    /// use, so an automatic ID never replaces an existing image.
    pub fn nextImageId(
        self: *ImageStorage,
        mode: enum { explicit, implicit },
    ) u32 {
        // Starting ID depends on mode.
        var id: u32 = switch (mode) {
            // Yeah, starting from 1 is wasteful. This matches what Kitty
            // does. In the future we can probably cache a low-water-mark
            // based on delete behavior.
            .explicit => 1,
            .implicit => self.next_image_id,
        };

        // Go through all possible images. We have +2 because we can
        // exceed the total by 1 (new ID).
        const count: usize = self.images.count();
        for (0..count + 2) |_| {
            if (id != 0 and !self.images.contains(id)) break;
            id +%= 1;
        }

        // Zero is never allowed.
        if (id == 0) id = 1;

        // Keep track of our next image id for implicit to speed that up.
        if (mode == .implicit) self.next_image_id = id +% 1;

        return id;
    }

    /// Add an image to the storage. This will automatically free any existing
    /// image with the same ID. Prefer addPendingImage for pending data so the
    /// caller receives a completion token.
    pub fn addImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        img: Image,
    ) Allocator.Error!void {
        const new_len = img.data.len();

        // If the image itself is over the limit, then error immediately
        if (new_len > self.total_limit) return error.OutOfMemory;

        // Credit an existing image's reservation before calculating the
        // replacement size. In particular, a completed live transmission
        // replacing pending snapshot metadata must be able to reuse the
        // reservation without evicting its own ID.
        const old_len = if (self.images.get(img.id)) |old|
            old.storageSize()
        else
            0;
        assert(old_len <= self.total_bytes);

        // Reserve map capacity before evicting anything so allocation failure
        // cannot leave storage partially evicted. Existing keys need no room.
        if (!self.images.contains(img.id)) {
            try self.images.ensureUnusedCapacity(alloc, 1);
        }

        // If this would put us over the limit, then evict.
        const total_bytes = self.total_bytes - old_len + new_len;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            log.info("evicting images to make space for {} bytes", .{req_bytes});
            if (!self.evictImageExcept(io, alloc, s, req_bytes, img.id)) {
                log.warn("failed to evict enough images for required bytes", .{});
                return error.OutOfMemory;
            }
        }

        const gop = self.images.getOrPutAssumeCapacity(img.id);

        log.debug("addImage image={}", .{img.withoutData()});

        if (gop.found_existing) {
            // Retransmitting a specific image ID replaces the old image and all
            // of its placements, as required by the Kitty graphics protocol.
            self.removePlacementsByImageId(s, img.id);

            // Relative placements parented to the removed placements go too.
            _ = self.removeOrphans(s, null);

            // Replacing an image drops its animation frames with it,
            // implementing the protocol rule that retransmitting the
            // base image resets the animation.
            self.total_bytes -= gop.value_ptr.storageSize();
            gop.value_ptr.deinit(alloc);
        }

        gop.value_ptr.* = img;
        gop.value_ptr.metadata.placement_count = 0;
        self.total_bytes += new_len;

        // Stamp the stored image with a fresh generation. This gives
        // every add/replace a unique stamp even when the same image ID
        // is retransmitted with identical dimensions, so consumers
        // (e.g. renderer texture caches) can detect content changes.
        self.markMutated(io);
        gop.value_ptr.generation = self.generation;
    }

    /// Add an image whose decoded payload bytes have not arrived yet.
    /// Returns the token required to complete this exact transmission.
    pub fn addPendingImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        img: Image,
    ) Allocator.Error!PendingImage {
        assert(img.data == .pending);
        try self.addImage(io, alloc, s, img);
        const stored = self.images.get(img.id).?;
        return .{ .id = stored.id, .generation = stored.generation };
    }

    /// Add a placement for a given image. The caller must verify in advance
    /// the image exists to prevent memory corruption. On success, storage
    /// owns `p`; on error, the caller retains ownership. The screen must own
    /// any tracked pin in `p` and in the placement it replaces.
    pub fn addPlacement(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        p: Placement,
    ) !void {
        assert(self.images.get(image_id) != null);
        log.debug("placement image_id={} placement_id={} placement={}\n", .{
            image_id,
            placement_id,
            p,
        });

        // When we add a placement, take this opportunity to reap garbage.
        // Garbage are placements that disappeared off scrollback (were
        // pruned). We don't clear Kitty state in the hot path so we do
        // this opportunistically here.
        self.reapGarbagePlacements(io, s);

        // The important piece here is that the placement ID needs to
        // be marked internal if it is zero. This allows multiple placements
        // to be added for the same image. If it is non-zero, then it is
        // an external placement ID and we can only have one placement
        // per (image id, placement id) pair.
        const key: PlacementKey = .{
            .image_id = image_id,
            .placement_id = if (placement_id == 0) .{
                .tag = .internal,
                .id = id: {
                    defer self.next_internal_placement_id +%= 1;
                    break :id self.next_internal_placement_id;
                },
            } else .{
                .tag = .external,
                .id = placement_id,
            },
        };

        const gop = try self.placements.getOrPut(alloc, key);
        if (gop.found_existing) {
            gop.value_ptr.deinit(s);
        } else {
            const img = self.images.getPtr(image_id).?;
            img.metadata.placement_count = std.math.add(
                @TypeOf(img.metadata.placement_count),
                img.metadata.placement_count,
                1,
            ) catch {
                self.placements.removeByPtr(gop.key_ptr);
                return error.OutOfMemory;
            };
        }
        gop.value_ptr.* = p;

        // This always mutates
        self.markMutated(io);
    }

    /// How the row operation behind a scrollMarginsBegin/end pair moves
    /// tracked pins, which determines how much repositioning work the
    /// placements need.
    pub const ScrollOp = enum {
        /// The operation shifts the entire active window down (it
        /// creates scrollback), so every placement anchored in the
        /// active area changes active position and must be restored.
        window_shift,

        /// The operation moves rows in place within the scrolling
        /// region: pins anchored outside the region rows keep their
        /// active position without help, so only placements anchored
        /// inside the region rows need handling. This is the common
        /// case (e.g. a status bar image beside a scrolling pane
        /// costs almost nothing per scroll).
        in_place,
    };

    /// Adjust placements for a scroll of the terminal's scrolling region
    /// by `delta` rows (negative moves content up). This implements the
    /// Kitty graphics protocol behavior for scrolls bounded by margins:
    /// placements entirely inside the scrolling region move with the content
    /// and are clipped when the move would extend them past a margin (deleted
    /// when fully clipped), while every other placement (straddling a margin,
    /// outside the region, or in the scrollback) must not move at all.
    ///
    /// This is split into two phases around the row operation because
    /// the various scroll implementations move tracked pins in
    /// inconsistent ways (some shift the active area so every pin moves,
    /// some rotate rows in place and adjust only pins inside the
    /// region). We record the desired final position of every placement
    /// up front in the returned state, whose end() repositions the pins
    /// once the rows have settled, making the result independent of the
    /// path taken. Every call must be paired with exactly one end().
    ///
    /// Callers must skip this entirely when the scrolling region is the
    /// full screen: a full-screen scroll moves placements with their
    /// anchored rows (possibly into the scrollback) via pin tracking,
    /// which already matches kitty's marginless scroll behavior.
    pub fn scrollMarginsBegin(
        self: *ImageStorage,
        io: std.Io,
        t: *terminal.Terminal,
        delta: isize,
        op: ScrollOp,
    ) ScrollMargins {
        const s: *terminal.Screen = t.screens.active;
        assert(self == &s.kitty_images);
        var result: ScrollMargins = .{ .screen = s };

        const top: i64 = t.scrolling_region.top;
        const bottom: i64 = t.scrolling_region.bottom;

        var mutated = false;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const p: *Placement = entry.value_ptr;

            // Virtual placements follow their placeholder cells and
            // relative placements follow their parents, so neither is
            // ever adjusted by scrolls, matching kitty.
            const pin: *PageList.Pin = switch (p.location) {
                .pin => |pin| pin,
                .virtual, .relative => continue,
            };

            // Pruned placements are reaped by reapGarbagePlacements.
            if (pin.garbage) continue;

            // Placements anchored outside the active area (scrollback)
            // are never touched by a scroll within the margins.
            const coord = (s.pages.pointFromPin(
                .active,
                pin.*,
            ) orelse continue).coord();
            const y: i64 = coord.y;

            // An in-place operation doesn't touch pins anchored outside
            // the region rows, and a placement anchored there can never
            // be entirely inside the region, so it needs no work at all.
            if (op == .in_place and (y < top or y > bottom)) continue;

            // The final position defaults to unmoved; restoring the pin
            // to this exact spot afterwards is what stops the row
            // operations from dragging the placement around.
            var final_y: i64 = y;

            inside: {
                const image = self.images.get(entry.key_ptr.image_id) orelse break :inside;
                const grid = p.gridSize(image, t);

                // Unknown geometry (e.g. pixel sizes not yet reported)
                // means we can't know the extent, so we can't consider
                // the placement contained.
                if (grid.rows == 0 or grid.cols == 0) break :inside;

                // Only placements entirely within the scrolling region
                // move. Kitty only has top/bottom margins so it only
                // checks rows; the column check is our generalization
                // for left/right margins and is trivially true for
                // full-width regions.
                if (y < top or y + grid.rows - 1 > bottom) break :inside;
                const x: i64 = coord.x;
                if (x < t.scrolling_region.left or
                    @min(x + grid.cols - 1, @as(i64, t.cols) - 1) > t.scrolling_region.right) break :inside;

                const new_y: i64 = y + delta;
                const rows: i64 = grid.rows;
                const top_clip: i64 = @max(0, top - new_y);
                const bottom_clip: i64 = @max(0, new_y + rows - 1 - bottom);
                const visible: bool = clip: {
                    if (top_clip >= rows or bottom_clip >= rows) break :clip false;

                    if (top_clip > 0) {
                        if (!p.clipTop(
                            image,
                            t,
                            @intCast(top_clip),
                            grid.rows,
                        )) break :clip false;
                        mutated = true;
                        final_y = top;
                        break :clip true;
                    }

                    if (bottom_clip > 0) {
                        if (!p.clipBottom(
                            image,
                            t,
                            @intCast(bottom_clip),
                            grid.rows,
                        )) break :clip false;
                        mutated = true;
                    }

                    final_y = new_y;
                    break :clip true;
                };

                // Scrolled or clipped entirely out of the region: the
                // placement is deleted, like kitty. The image itself is
                // retained for future placements.
                if (!visible) {
                    self.removePlacement(s, entry);
                    mutated = true;
                    continue;
                }
            }

            result.restores.append(s.alloc, .{
                .pin = pin,
                .x = pin.x,
                .y = @intCast(final_y),
            }) catch {
                // OOM: this placement is left to the whims of the
                // generic pin tracking. Degraded, but safe.
                log.warn("OOM adjusting image placement for scroll", .{});
                continue;
            };
        }

        if (mutated) {
            // Placements deleted by clipping may orphan relative placements.
            // Orphans have no pins so this never touches the restores.
            _ = self.removeOrphans(s, null);
            self.markMutated(io);
        }

        return result;
    }

    /// Reap pin-backed placements whose tracked content has been pruned
    /// from history, along with any relative placements orphaned by
    /// that, marking the content mutation.
    ///
    /// Virtual and relative placements have no tracked screen location and
    /// are never pruned themselves. Kitty removes placements once they
    /// scroll out of retained history.
    fn reapGarbagePlacements(
        self: *ImageStorage,
        io: std.Io,
        s: *terminal.Screen,
    ) void {
        var removed = false;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                .virtual, .relative => continue,
            };
            if (!pin.garbage) continue;

            self.removePlacement(s, entry);
            removed = true;
        }
        if (!removed) return;

        // If we removed a placement, then also remove any orphan
        // children if this was a parent.
        _ = self.removeOrphans(s, null);

        self.markMutated(io);
    }

    fn clearPlacements(self: *ImageStorage, s: *terminal.Screen) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(s);
        self.placements.clearRetainingCapacity();
    }

    fn removePlacementsByImageId(
        self: *ImageStorage,
        s: *terminal.Screen,
        image_id: u32,
    ) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.image_id != image_id) continue;
            self.removePlacement(s, entry);
        }
    }

    /// Remove a placement by its map entry, releasing any tracked pin
    /// and keeping the image's placement count in sync. The entry must
    /// point into the placements map (via iteration or getEntry).
    fn removePlacement(
        self: *ImageStorage,
        s: *terminal.Screen,
        entry: PlacementMap.Entry,
    ) void {
        entry.value_ptr.deinit(s);
        const img = self.images.getPtr(entry.key_ptr.image_id).?;
        assert(img.metadata.placement_count > 0);
        img.metadata.placement_count -= 1;
        self.placements.removeByPtr(entry.key_ptr);
    }

    /// Remove relative placements whose parent placement no longer
    /// exists, keeping a relative placement's lifetime tied to its
    /// parent chain. Chains can be several links deep, so this loops
    /// until a pass removes nothing to take out entire orphaned
    /// subtrees. Returns true if anything was removed.
    ///
    /// If `delete_unused` is non-null, an image left without placements
    /// by the reap is freed using it. This matches uppercase delete
    /// semantics; every other removal path retains image data and
    /// passes null.
    ///
    /// This must be called, outside of any placements iteration, after
    /// every operation that removes placements. Kitty gets the same
    /// effect lazily by dropping unresolvable placements while drawing;
    /// we do it eagerly because our renderer never mutates terminal
    /// state.
    fn removeOrphans(
        self: *ImageStorage,
        s: *terminal.Screen,
        delete_unused: ?Allocator,
    ) bool {
        var removed_any = false;
        var removed = true;
        while (removed) {
            removed = false;
            var it = self.placements.iterator();
            while (it.next()) |entry| {
                const rel = switch (entry.value_ptr.location) {
                    .relative => |rel| rel,
                    .pin, .virtual => continue,
                };
                if (self.placements.contains(rel.parent)) continue;

                // Parent is gone, remove this placement.
                const image_id = entry.key_ptr.image_id;
                self.removePlacement(s, entry);
                removed = true;
                removed_any = true;

                if (delete_unused) |alloc| self.deleteIfUnused(
                    alloc,
                    image_id,
                );
            }
        }

        return removed_any;
    }

    /// Maximum number of parent links in a relative placement chain,
    /// matching the minimum specified in the spec and the actual
    /// limit defined by Kitty at the time of authoring.
    pub const parent_chain_limit = 8;

    pub const ParentError = error{
        /// The parent image (P=) does not exist.
        ParentImageNotFound,
        /// The parent image exists but the requested placement (Q=, or
        /// any placement when Q is omitted) does not.
        ParentPlacementNotFound,
        /// The placement refers to itself as its own parent.
        SelfParent,
        /// The parent chain loops back to the placement being created.
        Cycle,
        /// The parent chain exceeds parent_chain_limit links.
        TooDeep,
        /// An ancestor in the chain no longer exists. This should not
        /// happen since removeOrphans keeps chains intact, but we
        /// check anyway rather than trusting the invariant.
        AncestorNotFound,
    };

    /// Resolve and validate the parent reference (P=/Q=) of a relative
    /// placement, returning the concrete key of the parent placement.
    /// `child` is the key of the placement being created when it is
    /// addressable (an explicit placement ID); null for placements that
    /// will receive a fresh internal ID, which nothing can refer to yet.
    ///
    /// Checks: the parent must exist, the placement must not
    /// parent itself, and the resulting ancestor chain must be acyclic
    /// and within parent_chain_limit.
    pub fn resolveParent(
        self: *ImageStorage,
        io: std.Io,
        s: *terminal.Screen,
        child: ?PlacementKey,
        parent_image_id: u32,
        parent_placement_id: u32,
    ) ParentError!PlacementKey {
        // Reap placements whose content has been pruned from history
        // before resolving: a pruned parent must be reported as missing,
        // not accepted and then immediately reaped by addPlacement's own
        // sweep, which would store an orphan.
        self.reapGarbagePlacements(io, s);

        // If the parent doesn't exist we're already failed.
        if (!self.images.contains(parent_image_id)) {
            return error.ParentImageNotFound;
        }

        // Find the parent
        const parent: PlacementKey = parent: {
            // An explicit parent placement ID (Q=) selects exactly that
            // placement.
            if (parent_placement_id > 0) {
                const key: PlacementKey = .{
                    .image_id = parent_image_id,
                    .placement_id = .{
                        .tag = .external,
                        .id = parent_placement_id,
                    },
                };
                if (!self.placements.contains(key)) {
                    return error.ParentPlacementNotFound;
                }
                break :parent key;
            }

            // No Q: pick a placement of the parent image. Kitty picks
            // the oldest surviving placement; our placement map doesn't
            // track creation order so we pick by PlacementId.preferredOver
            // instead. This is unspecified so any behavior here is fine.
            // In practice the parent image has a single placement, and
            // clients use Q when it doesn't.
            const best: PlacementId = best: {
                var best: ?PlacementId = null;
                var it = self.placements.keyIterator();
                while (it.next()) |key| {
                    if (key.image_id != parent_image_id) continue;
                    const id = key.placement_id;
                    const b = best orelse {
                        best = id;
                        continue;
                    };
                    if (id.preferredOver(b)) best = id;
                }
                break :best best orelse return error.ParentPlacementNotFound;
            };

            break :parent .{
                .image_id = parent_image_id,
                .placement_id = best,
            };
        };

        // A placement cannot be its own parent. This must be checked
        // before the chain walk so it reports EINVAL, not ECYCLE.
        if (child) |c| if (parent.eql(c)) return error.SelfParent;

        // Walk the would-be ancestor chain. `depth` counts parent links,
        // starting at one for the link we are about to create.
        var depth: usize = 1;
        var key = parent;
        while (true) {
            if (child) |c| if (key.eql(c)) return error.Cycle;
            const p = self.placements.get(key) orelse return error.AncestorNotFound;
            const rel = switch (p.location) {
                .relative => |rel| rel,
                // A pin or virtual placement is the chain root.
                .pin, .virtual => break,
            };
            if (depth >= parent_chain_limit) return error.TooDeep;
            depth += 1;
            key = rel.parent;
        }

        return parent;
    }

    /// The result of resolving a relative placement's parent chain:
    /// the chain's root placement (always pin or virtual, never
    /// relative) and the total cell offset from the root's origin.
    pub const ResolvedChain = struct {
        root_key: PlacementKey,
        root: Placement,
        horizontal_offset: i32,
        vertical_offset: i32,
    };

    /// Resolve a relative placement's parent chain to its root,
    /// accumulating the cell offsets (H=/V=) of every link on the way.
    /// The placement's position is the root's origin plus the accumulated
    /// offsets.
    ///
    /// Returns null when the chain is broken or too deep. Neither can
    /// normally happen for stored placements (resolveParent validates
    /// chains and removeOrphans removes broken ones), with one kitty
    /// quirk: replacing an ancestor placement can deepen the chains
    /// below it beyond parent_chain_limit after the fact.
    pub fn resolveChain(
        self: *const ImageStorage,
        rel: Placement.Relative,
    ) ?ResolvedChain {
        var horizontal = rel.horizontal_offset;
        var vertical = rel.vertical_offset;
        var key = rel.parent;
        var depth: usize = 1;
        while (true) {
            const p = self.placements.get(key) orelse return null;
            switch (p.location) {
                .relative => |parent_rel| {
                    if (depth >= parent_chain_limit) return null;
                    depth += 1;
                    horizontal +|= parent_rel.horizontal_offset;
                    vertical +|= parent_rel.vertical_offset;
                    key = parent_rel.parent;
                },

                .pin, .virtual => return .{
                    .root_key = key,
                    .root = p,
                    .horizontal_offset = horizontal,
                    .vertical_offset = vertical,
                },
            }
        }
    }

    /// Returns the placement that a unicode placeholder cell referencing
    /// this image/placement ID pair targets, or null if there is none. A
    /// zero placement ID targets one of the image's virtual placements,
    /// chosen by PlacementId.preferredOver so the choice is stable (an
    /// image rarely has more than one). This is the shared lookup used
    /// both for sizing placeholder runs and for positioning relative
    /// placements whose chain roots at a virtual placement.
    pub fn placeholderTarget(
        self: *const ImageStorage,
        image_id: u32,
        placement_id: u32,
    ) ?struct { key: PlacementKey, placement: Placement } {
        if (placement_id > 0) {
            const key: PlacementKey = .{
                .image_id = image_id,
                .placement_id = .{ .tag = .external, .id = placement_id },
            };
            const p = self.placements.get(key) orelse return null;
            return .{ .key = key, .placement = p };
        }

        var best: ?PlacementKey = null;
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.image_id != image_id) continue;
            if (entry.value_ptr.location != .virtual) continue;
            const b = best orelse {
                best = entry.key_ptr.*;
                continue;
            };
            if (entry.key_ptr.placement_id.preferredOver(b.placement_id)) {
                best = entry.key_ptr.*;
            }
        }

        const key = best orelse return null;
        return .{ .key = key, .placement = self.placements.get(key).? };
    }

    /// Get an image by its ID. If the image doesn't exist, null is returned.
    pub fn imageById(self: *const ImageStorage, image_id: u32) ?Image {
        return self.images.get(image_id);
    }

    /// Get an image by its number. If the image doesn't exist, return null.
    pub fn imageByNumber(self: *const ImageStorage, image_number: u32) ?Image {
        var newest: ?Image = null;

        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number == image_number) {
                if (newest == null or
                    kv.value_ptr.generation > newest.?.generation)
                {
                    newest = kv.value_ptr.*;
                }
            }
        }

        return newest;
    }

    /// Get a mutable pointer to a stored image, by ID or (newest by)
    /// number, following the protocol's id/number addressing. Used by
    /// the animation commands, which mutate images in place. The
    /// pointer is invalidated by any operation that adds or removes
    /// images.
    pub fn imagePtrByIdOrNumber(
        self: *const ImageStorage,
        image_id: u32,
        image_number: u32,
    ) ?*Image {
        if (image_id != 0) return self.images.getPtr(image_id);

        var newest: ?*Image = null;
        var it = self.images.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.number != image_number) continue;
            if (newest == null or
                kv.value_ptr.generation > newest.?.generation)
            {
                newest = kv.value_ptr;
            }
        }

        return newest;
    }

    /// Record that the displayed content of an image changed without
    /// the image being re-added: marks the storage mutated and stamps
    /// the image with the fresh generation so consumers (e.g. the
    /// renderer's texture cache) replace what they hold. Used when an
    /// animation changes which frame is current or edits the current
    /// frame's pixels.
    pub fn markImageContentChanged(
        self: *ImageStorage,
        io: std.Io,
        img: *Image,
    ) void {
        self.markMutated(io);
        img.generation = self.generation;
    }

    /// Convert a stored image's base data to RGBA in place, adjusting
    /// byte accounting. All animation composition happens in RGBA;
    /// this is called before the first composition into an image.
    ///
    /// The pixels are unchanged visually but the stored representation
    /// changed, so the image is stamped with a fresh generation.
    pub fn convertImageToRgba(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        img: *Image,
    ) Allocator.Error!void {
        if (img.format == .rgba) return;
        const old = img.data.bytes() orelse return;

        const rgba = try pixel.rgbaFromFormat(alloc, img.format, old);
        self.total_bytes -= old.len;
        self.total_bytes += rgba.len;
        img.data.deinit(alloc);
        img.data = .{ .complete = rgba };
        img.format = .rgba;
        self.markImageContentChanged(io, img);
    }

    /// Reserve `bytes` of storage for animation frame data belonging
    /// to `image_id`, evicting other images if needed, mirroring how
    /// image transmission reserves space.
    ///
    /// Errors if the space cannot be made available. On success the caller
    /// owns the reservation and must either attach the frame data to the
    /// image or call releaseAnimationBytes.
    pub fn reserveAnimationBytes(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        bytes: usize,
    ) Allocator.Error!void {
        if (bytes > self.total_limit) return error.OutOfMemory;

        const total_bytes = self.total_bytes + bytes;
        if (total_bytes > self.total_limit) {
            const req_bytes = total_bytes - self.total_limit;
            // Excess this large cannot be recovered by evicting other
            // images (evictImageExcept also requires it).
            if (req_bytes > self.total_limit) return error.OutOfMemory;
            log.info("evicting images for animation frame, evicting={}", .{req_bytes});
            if (!self.evictImageExcept(
                io,
                alloc,
                s,
                req_bytes,
                image_id,
            )) {
                log.warn("failed to evict enough images for animation frame", .{});
                return error.OutOfMemory;
            }
        }

        self.total_bytes += bytes;
    }

    /// Release a reservation made by reserveAnimationBytes, or credit
    /// bytes freed by deleting animation frame data.
    pub fn releaseAnimationBytes(self: *ImageStorage, bytes: usize) void {
        assert(bytes <= self.total_bytes);
        self.total_bytes -= bytes;
    }

    /// Advance every running animation to the frame that should be
    /// displayed at `now_ms` and report when the next frame change is
    /// due, as a delay in milliseconds relative to `now_ms`. Null
    /// means no running animation needs a future tick.
    ///
    /// `now_ms` is a monotonic timestamp on a clock of the caller's
    /// choosing. The same clock must be used for every call. The
    /// caller is expected to be the renderer, ticking once per frame
    /// build and scheduling a wakeup for the returned delay.
    pub fn animationTick(self: *ImageStorage, io: std.Io, now_ms: u64) ?u64 {
        var min_delay: ?u64 = null;

        var it = self.images.iterator();
        while (it.next()) |entry| {
            const img: *Image = entry.value_ptr;

            // The gates below mirror Kitty's image_is_animatable.

            // No animation state was ever attached (plain image).
            const anim = img.animation orelse continue;

            // Stopped is the initial state of every animation: frames
            // then only change client-driven (a=a c=N), never by time.
            if (anim.state == .stopped) continue;

            // Only the root frame exists; there is nothing to advance
            // to yet even in the running state.
            if (anim.frames.items.len == 0) continue;

            // Unplaced images don't animate. This is our simpler
            // approximation of Kitty's "is actually drawn" visibility
            // gate; it is what stops an image that was transmitted but
            // never placed from waking the renderer forever.
            if (img.metadata.placement_count == 0) continue;

            // The base pixel data hasn't arrived yet (e.g. an image
            // restored from a snapshot); nothing can be displayed.
            if (img.data.isPending()) continue;

            // A zero total duration means every frame is gapless and
            // no frame can ever be displayed, so the animation can
            // never advance. This also guards the gapless-skip loop
            // below from never terminating.
            if (anim.durationMs() == 0) continue;

            // A finite loop budget (a=a v=N) that ran out on an
            // earlier tick froze playback on the last frame for good.
            if (anim.max_loops > 0 and anim.current_loop >= anim.max_loops) continue;

            const shown_at: u64 = shown_at: {
                // First tick since playback started (or since the
                // current frame changed through another path, e.g.
                // a=a c=N): the frame is considered shown as of now,
                // and its gap starts counting from here.
                const at = anim.frame_shown_at_ms orelse break :shown_at now_ms;

                // A timestamp from the future means the caller's clock
                // restarted; re-anchor rather than stalling until the
                // old timestamp comes around again.
                if (at > now_ms) break :shown_at now_ms;

                break :shown_at at;
            };
            anim.frame_shown_at_ms = shown_at;

            // The current frame is replaced once its gap has elapsed.
            // We advance at most one displayed frame per tick with no
            // catch-up, exactly like Kitty: if ticks lag behind the
            // gaps, the animation slows down rather than skipping.
            var next_at: u64 = shown_at +| anim.gapAt(anim.current_index);
            if (now_ms >= next_at) advance: {
                // Walk forward to the next displayable frame. This is
                // a loop only because gapless (gap=0) frames are never
                // displayed and are stepped over; the durationMs gate
                // above guarantees a displayable frame exists.
                const count: u32 = anim.frameCount();
                var idx = anim.current_index;
                while (true) {
                    const next = (idx + 1) % count;
                    if (next == 0) {
                        // Wrapping past the last frame back to the
                        // root. A loading-state (a=a s=2) animation
                        // refuses the wrap: it parks on the last frame
                        // awaiting more frames from the client.
                        if (anim.state == .loading) break :advance;

                        // Each wrap completes a loop; a finite budget
                        // that just ran out parks on the last frame.
                        anim.current_loop += 1;
                        if (anim.max_loops > 0 and
                            anim.current_loop >= anim.max_loops) break :advance;
                    }
                    idx = next;
                    if (anim.gapAt(idx) != 0) break;
                }

                // Show the chosen frame: restart its gap timer and
                // stamp a fresh generation so consumers (the renderer
                // texture cache, the C API) pick up the new pixels.
                anim.current_index = idx;
                anim.frame_shown_at_ms = now_ms;
                self.markImageContentChanged(io, img);
                next_at = now_ms +| anim.gapAt(idx);
            }

            // Schedule the next tick. A parked animation left next_at
            // in the past and so never schedules one; it is woken by
            // its trigger instead (a new frame arriving, or an a=a
            // command changing the state).
            if (next_at > now_ms) {
                const delay = next_at - now_ms;
                min_delay = if (min_delay) |m| @min(m, delay) else delay;
            }
        }

        return min_delay;
    }

    /// Clear placements intersecting the active screen, then reclaim every
    /// image with no remaining placement. Unlike protocol d=A, a terminal
    /// clear also reclaims images that were already unplaced.
    pub fn clearScreen(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        t: *terminal.Terminal,
    ) void {
        const placements_before = self.placements.count();
        const images_before = self.images.count();

        // Delete unused placements and images. Orphaned relative
        // placements must be reaped before the image sweep so that
        // their images are reclaimable too.
        self.deleteVisiblePlacements(alloc, t, true);
        _ = self.removeOrphans(t.screens.active, null);
        var image_it = self.images.iterator();
        while (image_it.next()) |entry| {
            self.deleteIfUnused(alloc, entry.key_ptr.*);
        }

        // Mark mutated only if things changed.
        if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated(io);
    }

    /// Delete placements, images.
    pub fn delete(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        t: *terminal.Terminal,
        cmd: command.Delete.Action,
    ) void {
        // Deletes only ever remove placements/images, so comparing counts
        // before and after tells us whether anything actually changed.
        // Only then do we mark a mutation, so a delete that matches nothing
        // doesn't dirty the image state or bump the generation.
        const placements_before = self.placements.count();
        const images_before = self.images.count();
        defer if (self.placements.count() != placements_before or
            self.images.count() != images_before) self.markMutated(io);

        switch (cmd) {
            .all => |delete_images| self.deleteVisiblePlacements(
                alloc,
                t,
                delete_images,
            ),

            .id => |v| self.deleteById(
                alloc,
                t.screens.active,
                v.image_id,
                v.placement_id,
                v.delete,
            ),

            .newest => |v| newest: {
                const img = self.imageByNumber(v.image_number) orelse break :newest;
                self.deleteById(
                    alloc,
                    t.screens.active,
                    img.id,
                    v.placement_id,
                    v.delete,
                );
            },

            .intersect_cursor => |delete_images| {
                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = t.screens.active.cursor.x,
                        .y = t.screens.active.cursor.y,
                    } },
                    delete_images,
                    {},
                    null,
                );
            },

            .intersect_cell => |v| intersect_cell: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell,
                    } },
                    v.delete,
                    {},
                    null,
                );
            },

            .intersect_cell_z => |v| intersect_cell_z: {
                if (v.x <= 0 or v.y <= 0) {
                    log.warn("delete intersect cell coords must be at least 1", .{});
                    break :intersect_cell_z;
                }

                self.deleteIntersecting(
                    alloc,
                    t,
                    .{ .active = .{
                        .x = std.math.cast(size.CellCountInt, v.x - 1) orelse break :intersect_cell_z,
                        .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :intersect_cell_z,
                    } },
                    v.delete,
                    v.z,
                    struct {
                        fn filter(ctx: i32, p: Placement) bool {
                            return p.z == ctx;
                        }
                    }.filter,
                );
            },

            .column => |v| column: {
                if (v.x <= 0) {
                    log.warn("delete column must be greater than zero", .{});
                    break :column;
                }

                const x = v.x - 1;
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;
                    if (rect.top_left.x <= x and rect.bottom_right.x >= x) {
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .row => |v| row: {
                if (v.y <= 0) {
                    log.warn("delete row must be greater than zero", .{});
                    break :row;
                }

                // v.y is in active coords so we want to convert it to a pin
                // so we can compare by page offsets.
                const target_pin = t.screens.active.pages.pin(.{ .active = .{
                    .y = std.math.cast(size.CellCountInt, v.y - 1) orelse break :row,
                } }) orelse break :row;

                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    const img = self.imageById(entry.key_ptr.image_id) orelse continue;
                    const rect = entry.value_ptr.rect(img, t) orelse continue;

                    // We need to copy our pin to ensure we are at least at
                    // the top-left x.
                    var target_pin_copy = target_pin;
                    target_pin_copy.x = rect.top_left.x;
                    if (target_pin_copy.isBetween(rect.top_left, rect.bottom_right)) {
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, img.id);
                    }
                }
            },

            .z => |v| {
                var it = self.placements.iterator();
                while (it.next()) |entry| {
                    switch (entry.value_ptr.location) {
                        // Relative placements carry their own z value and
                        // are matched by z deletes just like kitty does.
                        .pin, .relative => {},

                        // Virtual placeholders cannot delete by z according
                        // to the spec.
                        .virtual => continue,
                    }

                    if (entry.value_ptr.z == v.z) {
                        const image_id = entry.key_ptr.image_id;
                        self.removePlacement(t.screens.active, entry);
                        if (v.delete) self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            .range => |v| range: {
                // Both bounds default to zero when omitted. An inverted range
                // or a zero upper bound is not an error, it just selects
                // nothing: image IDs are always non-zero.
                if (v.last == 0 or v.first > v.last) break :range;

                // Remove matching placements in one pass.
                var placement_it = self.placements.iterator();
                while (placement_it.next()) |entry| {
                    if (entry.key_ptr.image_id < v.first or
                        entry.key_ptr.image_id > v.last) continue;

                    self.removePlacement(t.screens.active, entry);
                }

                // Uppercase deletion also frees matching images that are now
                // unused, including images that had no placements initially.
                if (!v.delete) break :range;
                var image_it = self.images.iterator();
                while (image_it.next()) |entry| {
                    const image_id = entry.key_ptr.*;
                    if (image_id >= v.first and image_id <= v.last) {
                        self.deleteIfUnused(alloc, image_id);
                    }
                }
            },

            .animation_frames => |v| self.deleteAnimationFrame(
                io,
                alloc,
                t.screens.active,
                v,
            ),
        }

        // Deleting placements orphans any relative placements parented
        // to them (transitively). Their lifetime is tied to the parent
        // so they are removed as well, and an uppercase delete also
        // frees any image the cascade leaves without placements (the
        // per-branch deleteIfUnused calls above ran while the orphans
        // still counted as placements).
        const delete_unused: bool = switch (cmd) {
            .all, .intersect_cursor => |v| v,
            inline else => |v| v.delete,
        };
        _ = self.removeOrphans(
            t.screens.active,
            if (delete_unused) alloc else null,
        );
    }

    /// Delete only non-virtual placements that intersect the active screen.
    /// The protocol defines d=a/A in terms of visible placements, and an
    /// uppercase delete only frees data for images selected by those
    /// placements.
    fn deleteVisiblePlacements(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        delete_unused: bool,
    ) void {
        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const pin = switch (entry.value_ptr.location) {
                .pin => |pin| pin,
                // Virtual placements are never selected by visible
                // deletes per the protocol. Relative placements are
                // removed with their parents instead (removeOrphans).
                .virtual, .relative => continue,
            };
            if (pin.garbage) continue;

            // Placements anchored in the active area are necessarily visible.
            // Only compute their extent when the anchor is already in history
            // and the bottom edge may still intersect the active area.
            if (t.screens.active.pages.pointFromPin(
                .active,
                pin.*,
            ) == null) {
                const image = self.imageById(entry.key_ptr.image_id) orelse continue;
                const rect = entry.value_ptr.rect(image, t) orelse continue;
                if (t.screens.active.pages.pointFromPin(.active, rect.bottom_right) == null) continue;
            }

            const image_id = entry.key_ptr.image_id;
            self.removePlacement(t.screens.active, entry);
            if (delete_unused) self.deleteIfUnused(alloc, image_id);
        }
    }

    fn deleteById(
        self: *ImageStorage,
        alloc: Allocator,
        s: *terminal.Screen,
        image_id: u32,
        placement_id: u32,
        delete_unused: bool,
    ) void {
        var matched = placement_id == 0;

        // If no placement, we delete all placements with the ID
        if (placement_id == 0) self.removePlacementsByImageId(
            s,
            image_id,
        ) else if (self.placements.getEntry(.{
            .image_id = image_id,
            .placement_id = .{
                .tag = .external,
                .id = placement_id,
            },
        })) |entry| {
            self.removePlacement(s, entry);
            matched = true;
        }

        // A placement ID narrows the selection to that exact placement, so an
        // unmatched selector must not free otherwise-unreferenced image data.
        // https://sw.kovidgoyal.net/kitty/graphics-protocol/#deleting-images
        if (delete_unused and matched) self.deleteIfUnused(alloc, image_id);
    }

    /// Delete an animation frame (d=f/F). Deletes never produce
    /// responses, so all failures are only logged. Kitty behaviors
    /// implemented here: on an image without extra frames a lowercase
    /// delete is a no-op while an uppercase delete removes the entire
    /// image, placements included; the frame number is clamped to the
    /// last frame and zero selects the root frame; deleting the root
    /// frame promotes frame 2 to be the new root.
    fn deleteAnimationFrame(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        v: command.Delete.Action.AnimationFrames,
    ) void {
        if (v.image_id == 0 and v.image_number == 0) {
            log.warn("delete animation frames requires image id or number", .{});
            return;
        }
        const img = self.imagePtrByIdOrNumber(
            v.image_id,
            v.image_number,
        ) orelse {
            log.warn(
                "delete animation frames for unknown image id={} number={}",
                .{ v.image_id, v.image_number },
            );
            return;
        };

        const anim: *animation.Animation = anim: {
            if (img.animation) |anim| {
                if (anim.frames.items.len > 0) break :anim anim;
            }

            // The image is not (or no longer) an animation. The
            // uppercase delete removes the entire image, even when it
            // still has placements.
            if (!v.delete) return;
            self.removePlacementsByImageId(s, img.id);
            const entry = self.images.getEntry(img.id).?;
            self.total_bytes -= entry.value_ptr.storageSize();
            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
            return;
        };

        // Clamp the frame number: zero selects the root frame and
        // values past the end select the last frame.
        const count: u32 = anim.frameCount();
        var number: u32 = @min(v.frame, count);
        if (number == 0) number = 1;

        if (number == 1) {
            // Deleting the root frame promotes frame 2 to root. The
            // promoted frame's bytes stay reserved; only the old root
            // data is freed.
            self.releaseAnimationBytes(img.data.len());
            img.data.deinit(alloc);
            const promoted = anim.frames.orderedRemove(0);
            img.data = .{ .complete = promoted.data };
            anim.root_gap_ms = promoted.gap_ms;
        } else {
            const removed = anim.frames.orderedRemove(number - 2);
            self.releaseAnimationBytes(removed.data.len);
            alloc.free(removed.data);
        }

        // Fix up the current frame.
        const removed_idx: u32 = if (number == 1) 0 else number - 2;
        const remaining: u32 = @intCast(anim.frames.items.len);
        if (anim.current_index > remaining) {
            anim.current_index = remaining;
            anim.frame_shown_at_ms = null;
            self.markImageContentChanged(io, img);
            return;
        }
        if (removed_idx == anim.current_index) {
            anim.frame_shown_at_ms = null;
            self.markImageContentChanged(io, img);
        } else {
            if (removed_idx < anim.current_index) anim.current_index -= 1;
            self.markMutated(io);
        }
    }

    /// Delete an image if it is unused.
    fn deleteIfUnused(self: *ImageStorage, alloc: Allocator, image_id: u32) void {
        const entry = self.images.getEntry(image_id) orelse return;
        if (entry.value_ptr.metadata.placement_count > 0) return;

        self.total_bytes -= entry.value_ptr.storageSize();
        entry.value_ptr.deinit(alloc);
        self.images.removeByPtr(entry.key_ptr);
    }

    /// Deletes all placements intersecting a screen point.
    fn deleteIntersecting(
        self: *ImageStorage,
        alloc: Allocator,
        t: *terminal.Terminal,
        p: point.Point,
        delete_unused: bool,
        filter_ctx: anytype,
        comptime filter: ?fn (@TypeOf(filter_ctx), Placement) bool,
    ) void {
        // Convert our target point to a pin for comparison.
        const target_pin = t.screens.active.pages.pin(p) orelse return;

        var it = self.placements.iterator();
        while (it.next()) |entry| {
            const img = self.imageById(entry.key_ptr.image_id) orelse continue;
            const rect = entry.value_ptr.rect(img, t) orelse continue;
            if (rect.contains(target_pin)) {
                if (filter) |f| if (!f(filter_ctx, entry.value_ptr.*)) continue;
                self.removePlacement(t.screens.active, entry);
                if (delete_unused) self.deleteIfUnused(alloc, img.id);
            }
        }
    }

    /// Evict image to make space. This will evict the oldest image,
    /// prioritizing transient images and unused images as recommended by the
    /// published Kitty spec.
    ///
    /// This will evict as many images as necessary to make space for
    /// req bytes.
    fn evictImage(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        req: usize,
    ) bool {
        return self.evictImageExcept(io, alloc, s, req, null);
    }

    /// Evict images while preserving `exclude_id`, used when replacing an
    /// existing image whose old reservation has already been credited.
    fn evictImageExcept(
        self: *ImageStorage,
        io: std.Io,
        alloc: Allocator,
        s: *terminal.Screen,
        req: usize,
        exclude_id: ?u32,
    ) bool {
        assert(req <= self.total_limit);

        const Candidate = struct {
            id: u32,
            generation: u64,

            // Lower values are evicted first:
            // 0: transient, unused
            // 1: not transient, unused
            // 2: transient, used
            // 3: not transient, used
            priority: u2,

            fn init(img: *const Image) @This() {
                return .{
                    .id = img.id,
                    .generation = img.generation,
                    .priority = (if (img.metadata.transient) @as(u2, 0) else @as(u2, 1)) +
                        (if (img.metadata.placement_count > 0) @as(u2, 2) else @as(u2, 0)),
                };
            }

            fn lessThan(lhs: @This(), rhs: @This()) bool {
                if (lhs.priority != rhs.priority)
                    return lhs.priority < rhs.priority;
                if (lhs.generation != rhs.generation)
                    return lhs.generation < rhs.generation;
                return lhs.id < rhs.id;
            }
        };

        // Evicting anything is a content mutation. This matters for the
        // setLimit path in particular, which doesn't otherwise mark it.
        // Evicted placements can also orphan relative placements of
        // other images, which must be reaped along with them.
        const images_before = self.images.count();
        defer if (self.images.count() != images_before) {
            _ = self.removeOrphans(s, null);
            self.markMutated(io);
        };

        var evicted: usize = 0;
        while (evicted < req) {
            const c = candidate: {
                var best: ?Candidate = null;
                var it = self.images.iterator();
                while (it.next()) |kv| {
                    const img = kv.value_ptr;
                    if (exclude_id != null and img.id == exclude_id.?) continue;

                    const current = Candidate.init(img);
                    if (best == null or current.lessThan(best.?)) best = current;
                }
                break :candidate best orelse return false;
            };

            var p_it = self.placements.iterator();
            while (p_it.next()) |entry| {
                if (entry.key_ptr.image_id == c.id) {
                    self.removePlacement(s, entry);
                }
            }

            const entry = self.images.getEntry(c.id).?;
            const image_len = entry.value_ptr.storageSize();
            log.info("evicting image id={} bytes={}", .{ c.id, image_len });

            evicted += image_len;
            self.total_bytes -= image_len;

            entry.value_ptr.deinit(alloc);
            self.images.removeByPtr(entry.key_ptr);
        }

        return true;
    }

    /// State returned by scrollMarginsBegin: the final active-area
    /// position every surviving placement pin must be restored to once
    /// the scrolled rows have settled. Every begin must be paired with
    /// exactly one end() call after the scroll's row operations
    /// complete.
    pub const ScrollMargins = struct {
        screen: *terminal.Screen,
        restores: std.ArrayListUnmanaged(Restore) = .empty,

        const Restore = struct {
            pin: *PageList.Pin,
            x: size.CellCountInt,
            y: u32,
        };

        /// Reposition every recorded placement pin to its post-scroll
        /// position and release the state. Must be called exactly
        /// once, after the scroll's row operations complete.
        pub fn end(self: *ScrollMargins) void {
            for (self.restores.items) |restore| {
                restore.pin.* = self.screen.pages.pin(.{ .active = .{
                    .x = restore.x,
                    .y = restore.y,
                } }) orelse continue;
            }
            self.restores.deinit(self.screen.alloc);
        }
    };

    /// Every placement is uniquely identified by the image ID and the
    /// placement ID. If an image ID isn't specified it is assumed to be 0.
    /// Likewise, if a placement ID isn't specified it is assumed to be 0.
    pub const PlacementKey = struct {
        image_id: u32,
        placement_id: PlacementId,

        pub fn eql(self: PlacementKey, other: PlacementKey) bool {
            return std.meta.eql(self, other);
        }
    };

    /// Internal placement IDs are assigned by us for placements created
    /// without an explicit ID (p=0); external IDs are client-specified.
    /// The two are separate namespaces, hence the tag.
    pub const PlacementId = packed struct {
        tag: enum(u1) { internal, external },
        id: u32,

        /// Deterministic preference order used when an operation must
        /// pick a single placement out of several (kitty uses creation
        /// order, which our map doesn't track): external IDs win over
        /// internal ones, and lower IDs win within a tag.
        pub fn preferredOver(self: PlacementId, other: PlacementId) bool {
            if (self.tag != other.tag) return self.tag == .external;
            return self.id < other.id;
        }
    };

    pub const Placement = struct {
        /// The location where this placement should be drawn.
        location: Location,

        /// Offset of the x/y from the top-left of the cell.
        x_offset: u32 = 0,
        y_offset: u32 = 0,

        /// Source rectangle for the image to pull from
        source_x: u32 = 0,
        source_y: u32 = 0,
        source_width: u32 = 0,
        source_height: u32 = 0,

        /// The columns/rows this image occupies.
        columns: u32 = 0,
        rows: u32 = 0,

        /// The z-index for this placement.
        z: i32 = 0,

        pub const Location = union(enum) {
            /// Exactly placed on a screen pin.
            pin: *PageList.Pin,

            /// Virtual placement (U=1) for unicode placeholders.
            virtual,

            /// Placed relative to a parent placement (P=/Q=). The
            /// placement has no screen position of its own; it is
            /// positioned at render time by resolving the parent chain
            /// to its root (see resolveChain) and therefore follows the
            /// parent through scrolls automatically. Its lifetime is
            /// tied to the parent: removing any ancestor removes it
            /// too (see removeOrphans).
            relative: Relative,
        };

        pub const Relative = struct {
            /// The parent placement. Resolved to a concrete key when
            /// the placement is created, so the parent is guaranteed
            /// to exist at that point.
            parent: PlacementKey,

            /// Cell offsets from the parent's origin (H=/V=).
            horizontal_offset: i32 = 0,
            vertical_offset: i32 = 0,
        };

        pub fn deinit(
            self: *const Placement,
            s: *terminal.Screen,
        ) void {
            switch (self.location) {
                .pin => |p| s.pages.untrackPin(p),
                .virtual, .relative => {},
            }
        }

        /// Multiply two protocol-controlled values without allowing them to
        /// wrap. Placement geometry is exposed as u32, so values larger than
        /// that are represented by the largest possible value.
        fn saturatingMul(lhs: u32, rhs: u32) u32 {
            return std.math.mul(u32, lhs, rhs) catch std.math.maxInt(u32);
        }

        /// Scale a dimension by an aspect ratio and round to the nearest
        /// integer. The u64 intermediate can hold the product of two u32s as
        /// well as the rounding adjustment.
        fn scaleDimension(value: u32, numerator: u32, denominator: u32) u32 {
            if (denominator == 0) return 0;

            const rounded = (@as(u64, value) * @as(u64, numerator) +
                @as(u64, denominator) / 2) / @as(u64, denominator);
            return std.math.cast(u32, rounded) orelse std.math.maxInt(u32);
        }

        pub const SourceRect = struct {
            x: u32,
            y: u32,
            width: u32,
            height: u32,
        };

        /// Returns the requested source rectangle intersected with the image.
        /// A zero width or height requests the full corresponding image
        /// dimension before intersection, as defined by the Kitty protocol.
        pub fn sourceRect(self: Placement, image: Image) SourceRect {
            const x = @min(self.source_x, image.width);
            const y = @min(self.source_y, image.height);
            return .{
                .x = x,
                .y = y,
                .width = @min(
                    if (self.source_width > 0) self.source_width else image.width,
                    image.width - x,
                ),
                .height = @min(
                    if (self.source_height > 0) self.source_height else image.height,
                    image.height - y,
                ),
            };
        }

        /// Returns the placement offset clamped within the first cell. Pixel
        /// geometry may temporarily be unavailable, in which case there is no
        /// valid offset within the cell.
        pub fn cellOffset(
            self: Placement,
            t: *const terminal.Terminal,
        ) struct {
            x: u32,
            y: u32,
        } {
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;

            return .{
                .x = if (cell_width > 0)
                    @min(self.x_offset, cell_width - 1)
                else
                    0,
                .y = if (cell_height > 0)
                    @min(self.y_offset, cell_height - 1)
                else
                    0,
            };
        }

        /// Returns the size of this placement's image in pixels,
        /// taking into account the source rectangle, specified
        /// rows/columns, and aspect ratio.
        pub fn pixelSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            width: u32,
            height: u32,
        } {
            const source = self.sourceRect(image);
            const width = source.width;
            const height = source.height;

            // If we don't have any specified cols or rows then the placement
            // should be the native size of the image, and doesn't need to be
            // re-scaled.
            if (self.columns == 0 and self.rows == 0) return .{
                .width = width,
                .height = height,
            };

            // We calculate the size of a cell so that we can multiply
            // it by the specified cols/rows to get the correct px size.
            //
            // We assume that the width is divided evenly by the column
            // count and the height by the row count, because it should be.
            const cell_width: u32 = t.width_px / t.cols;
            const cell_height: u32 = t.height_px / t.rows;
            const cell_offset = self.cellOffset(t);

            // If we have a specified cols AND rows then we calculate
            // the width and height from them directly, we don't need
            // to adjust for aspect ratio.
            if (self.columns > 0 and self.rows > 0) {
                const calc_width = saturatingMul(cell_width, self.columns);
                const calc_height = saturatingMul(cell_height, self.rows);

                return .{
                    .width = calc_width -| cell_offset.x,
                    .height = calc_height -| cell_offset.y,
                };
            }

            // Either the columns or the rows were specified, but not both,
            // so we need to calculate the other one based on the aspect ratio.

            // If only the columns were specified, we determine
            // the height of the image based on the aspect ratio.
            if (self.columns > 0) {
                const calc_width = saturatingMul(
                    cell_width,
                    self.columns,
                ) -| cell_offset.x;
                const calc_height = scaleDimension(calc_width, height, width);

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }

            // Otherwise, only the rows were specified, so we
            // determine the width based on the aspect ratio.
            {
                const calc_height = saturatingMul(
                    cell_height,
                    self.rows,
                ) -| cell_offset.y;
                const calc_width = scaleDimension(calc_height, width, height);

                return .{
                    .width = calc_width,
                    .height = calc_height,
                };
            }
        }

        /// Returns the size in grid cells that this placement takes up.
        pub fn gridSize(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) struct {
            cols: u32,
            rows: u32,
        } {
            // If we have a specified columns and rows then this is trivial.
            if (self.columns > 0 and self.rows > 0) return .{
                .cols = self.columns,
                .rows = self.rows,
            };

            // Otherwise we calculate the pixel size, divide by
            // cell size, and round up to the nearest integer.
            const calc_size = self.pixelSize(image, t);
            const cell_offset = self.cellOffset(t);
            return .{
                .cols = std.math.divCeil(
                    u32,
                    calc_size.width +| cell_offset.x,
                    t.width_px / t.cols,
                ) catch 0,
                .rows = std.math.divCeil(
                    u32,
                    calc_size.height +| cell_offset.y,
                    t.height_px / t.rows,
                ) catch 0,
            };
            // NOTE: Above `divCeil`s can only fail if the cell size is 0,
            //       in such a case it seems safe to return 0 for this.
        }

        /// Permanently clip `count` rows off the top of this placement,
        /// which currently spans `span` grid rows, by shrinking the
        /// source rectangle (the requested source rect is materialized
        /// into explicit values in the process). Used when a scroll
        /// within margins pushes the placement past the top margin.
        /// Requires 0 < count < span. Returns false if no visible
        /// source pixels would remain, in which case the placement is
        /// unmodified and should be deleted.
        fn clipTop(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
            span: u32,
        ) bool {
            assert(count > 0 and count < span);
            const src = self.sourceRect(image);
            const crop: u32 = if (self.rows > 0)
                // Scaled placement: each grid row shows an equal
                // fraction of the source.
                @intCast(@as(u64, src.height) * count / span)
            else
                // Native size: each grid row shows one cell height of
                // source pixels (kitty does the same).
                saturatingMul(t.height_px / t.rows, count);
            if (crop >= src.height) return false;
            self.source_x = src.x;
            self.source_y = src.y + crop;
            self.source_width = src.width;
            self.source_height = src.height - crop;
            if (self.rows > 0) self.rows -= count;
            return true;
        }

        /// clipTop, but clipping `count` rows off the bottom.
        fn clipBottom(
            self: *Placement,
            image: Image,
            t: *const terminal.Terminal,
            count: u32,
            span: u32,
        ) bool {
            assert(count > 0 and count < span);
            const src = self.sourceRect(image);
            // An empty source can never be clipped smaller. This also
            // guarantees we never store an explicit zero source height,
            // which would be reinterpreted as "full image".
            if (src.height == 0) return false;
            if (self.rows > 0) {
                const crop: u32 = @intCast(@as(u64, src.height) * count / span);
                if (crop >= src.height) return false;
                self.source_height = src.height - crop;
                self.rows -= count;
            } else {
                // The remaining rows can show this many source pixels,
                // with the first cell losing cellOffset pixels to the
                // placement's y offset.
                const visible = saturatingMul(t.height_px / t.rows, span - count);
                const offset = self.cellOffset(t).y;
                if (visible <= offset) return false;
                self.source_height = @min(src.height, visible - offset);
            }
            self.source_x = src.x;
            self.source_y = src.y;
            self.source_width = src.width;
            return true;
        }

        /// Returns a selection of the entire rectangle this placement
        /// occupies within the screen. This can return null for a virtual
        /// placement or when unavailable pixel geometry makes it empty.
        ///
        /// Relative placements also return null: they have no screen
        /// position of their own, so geometric queries (delete by
        /// intersection, row, column, etc.) never match them directly.
        /// They are instead removed when their parent chain is removed.
        pub fn rect(
            self: Placement,
            image: Image,
            t: *const terminal.Terminal,
        ) ?Rect {
            const grid_size = self.gridSize(image, t);
            const pin = switch (self.location) {
                .pin => |p| p,
                .virtual, .relative => return null,
            };
            if (pin.garbage) return null;

            // A zero pixel-sized placement can produce a zero grid size when
            // pixel geometry is unavailable. It occupies no rectangle.
            if (grid_size.cols == 0 or grid_size.rows == 0) return null;

            var br = switch (pin.downOverflow(grid_size.rows - 1)) {
                .offset => |v| v,
                .overflow => |v| v.end,
            };
            br.x = @intCast(@min(
                // We need to sub one here because the x value is
                // one width already. So if the image is width "1"
                // then we add zero to X because X itself is width 1.
                @as(u32, pin.x) +| (grid_size.cols - 1),
                @as(u32, t.cols) - 1,
            ));

            return .{
                .top_left = pin.*,
                .bottom_right = br,
            };
        }
    };
};

// Our pin for the placement
fn trackPin(
    t: *terminal.Terminal,
    pt: point.Coordinate,
) !*PageList.Pin {
    return try t.screens.active.pages.trackPin(t.screens.active.pages.pin(.{
        .active = pt,
    }).?);
}

test "storage: add placement with zero placement id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 0 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .internal, .id = 1 },
    }) != null);
}

test "storage: replacing placement releases tracked pin" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });

    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );

    const replacement_pin = try trackPin(&t, .{ .x = 2, .y = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = replacement_pin },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        replacement_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?.location.pin,
    );
}

test "storage: adding placement reclaims garbage placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 3, .rows = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });

    const tracked = t.screens.active.pages.countTrackedPins();
    const old_pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = old_pin },
    });
    old_pin.garbage = true;

    const new_pin = try trackPin(&t, .{ .x = 1, .y = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = new_pin },
    });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(
        tracked + 1,
        t.screens.active.pages.countTrackedPins(),
    );
    try testing.expectEqual(
        new_pin,
        s.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .internal, .id = 1 },
        }).?.location.pin,
    );
}

test "storage: placement count limit permits replacement" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .virtual = {} } });

    const img = s.images.getPtr(1).?;
    img.metadata.placement_count = std.math.maxInt(@TypeOf(img.metadata.placement_count));
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .virtual = {} } });
    try testing.expectError(
        error.OutOfMemory,
        s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .virtual = {} } }),
    );
    try testing.expectEqual(@as(usize, 1), s.placements.count());
}

test "storage: delete all visible placements and matching images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements and images preserves limit" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 5000;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 5000), s.total_limit);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all visible placements preserves scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);

    const history_key: ImageStorage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        s.placements.get(history_key).?.location.pin.*,
    ) == null);

    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });

    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(history_key));
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(1));
}

test "storage: delete all includes placements spanning into active area" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 2,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);

    const placement = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        placement.location.pin.*,
    ) == null);
    const rect = placement.rect(s.imageById(1).?, &t).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        rect.bottom_right,
    ) != null);

    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 0), s.images.count());
}

test "storage: delete all placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .all = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete all placements by image id and unused images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: delete placement by specific id" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 2,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: uppercase id delete preserves image when placement does not match" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });

    s.dirty = false;
    const generation = s.generation;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 7,
    } });

    try testing.expect(s.imageById(1) != null);
    try testing.expect(!s.dirty);
    try testing.expectEqual(generation, s.generation);
}

test "storage: uppercase id delete frees image after placement matches" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 9, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
        .placement_id = 9,
    } });

    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expect(s.dirty);
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: uppercase id delete without placement frees unplaced image" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{
        .delete = true,
        .image_id = 1,
    } });

    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expect(s.dirty);
}

test "storage: delete intersecting cursor" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = false });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    // This is inside the right placement and on an interior row shared by
    // both placements, but it is outside the left placement's columns.
    t.screens.active.cursorAbsolute(21, 5);
    s.delete(io, alloc, &t, .{ .intersect_cursor = false });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete intersecting cell checks interior row column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 10, .height = 10 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 20, .y = 0 }) } });

    // Protocol coordinates are one-based, so this targets grid cell (21, 5).
    s.delete(io, alloc, &t, .{ .intersect_cell = .{
        .x = 22,
        .y = 6,
    } });

    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete intersecting cursor plus unused" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(12, 12);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }) != null);
}

test "storage: delete intersecting cursor hits multiple" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    t.screens.active.cursorAbsolute(26, 26);

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .intersect_cursor = true });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete by column" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by column 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 0 }) } });

    s.delete(io, alloc, &t, .{ .column = .{
        .delete = false,
        .x = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete by row" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 50, .height = 50 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 25, .height = 25 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 25, .y = 25 }) } });

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 60,
    } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
}

test "storage: delete by row 1x1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 100, .cols = 100 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{ .location = .{ .pin = try trackPin(&t, .{ .y = 2 }) } });

    s.delete(io, alloc, &t, .{ .row = .{
        .delete = false,
        .y = 2,
    } });
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expectEqual(@as(usize, 1), s.images.count());

    // verify the placement is what we expect
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }) != null);
}

test "storage: delete images by range 1" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 2" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 1, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 3" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = false, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: delete images by range 4" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 3, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try testing.expectEqual(@as(usize, 3), s.images.count());
    try testing.expectEqual(@as(usize, 3), s.placements.count());

    s.dirty = false;
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 2, .last = 2 } });
    try testing.expect(s.dirty);
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());
    try testing.expect(s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expect(s.placements.get(.{
        .image_id = 3,
        .placement_id = .{ .tag = .external, .id = 1 },
    }) != null);
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: uppercase range deletes unplaced image data" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });

    s.delete(io, alloc, &t, .{
        .range = .{
            .delete = true,
            // Zero is the default lower bound when x is omitted.
            .first = 0,
            .last = 2,
        },
    });
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(3));
}

test "storage: delete images by empty range" {
    // Ranges that select nothing are a silent no-op, matching kitty, which
    // performs no validation and filters with `x <= image_id <= y`.
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);
    const tracked = t.screens.active.pages.countTrackedPins();

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });

    // Inverted range.
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 5, .last = 4 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    // Upper bound omitted, so it defaults to zero.
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 5, .last = 0 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    // Both bounds omitted. Image IDs are never zero so this matches nothing.
    s.delete(io, alloc, &t, .{ .range = .{ .delete = true, .first = 0, .last = 0 } });
    try testing.expectEqual(@as(usize, 2), s.images.count());
    try testing.expectEqual(@as(usize, 2), s.placements.count());

    // Both placements survive, so both of their pins are still tracked.
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());
}

test "storage: erase display preserves scrollback and reclaims unplaced images" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{
        .rows = 2,
        .cols = 2,
        .max_scrollback_bytes = 4096,
    });
    defer t.deinit(alloc);
    t.width_px = 2;
    t.height_px = 2;

    const s = &t.screens.active.kitty_images;
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try t.scrollUp(1);

    const history_key: ImageStorage.PlacementKey = .{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    };
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        s.placements.get(history_key).?.location.pin.*,
    ) == null);

    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .y = 0 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3, .width = 1, .height = 1 });

    t.eraseDisplay(.complete, false);
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(history_key));
    try testing.expectEqual(@as(usize, 1), s.images.count());
    try testing.expect(s.images.contains(1));
    try testing.expect(!s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}

test "storage: cell offsets stay within explicit destination rectangle" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    // Explicit columns and rows describe the far cell boundaries. Offsets
    // move the near edge inward without moving those far edges.
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = 3,
        .y_offset = 4,
        .columns = 2,
        .rows = 1,
    };
    const actual = placement.pixelSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 17), actual.width);
    try testing.expectEqual(@as(u32, 16), actual.height);
    try testing.expectEqual(@as(u32, 2), placement.gridSize(.{ .width = 4, .height = 3 }, &t).cols);
    try testing.expectEqual(@as(u32, 1), placement.gridSize(.{ .width = 4, .height = 3 }, &t).rows);
}

test "storage: cell offsets clamp to cell bounds" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);
    t.width_px = 50; // 10 px per col
    t.height_px = 100; // 20 px per row

    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .x_offset = std.math.maxInt(u32),
        .y_offset = std.math.maxInt(u32),
        .columns = 1,
        .rows = 1,
    };
    const offset = placement.cellOffset(&t);
    try testing.expectEqual(@as(u32, 9), offset.x);
    try testing.expectEqual(@as(u32, 19), offset.y);

    // Even hostile offsets leave one pixel inside the requested cell.
    const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 1), actual.height);
}

test "storage: aspect ratio calculation when only columns or rows specified" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 100, .rows = 100 });
    defer t.deinit(alloc);
    t.width_px = 1000; // 10 px per col
    t.height_px = 2000; // 20 px per row

    // Case 1: Only columns specified
    {
        const image = Image{ .id = 1, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 10,
            .rows = 0,
        };

        // Image is 16x9, set to a width of 10 columns, at 10px per column
        // that's 100px width. 100px * (9 / 16) = 56.25, which should round
        // to a height of 56px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 100), calc_size.width);
        try testing.expectEqual(@as(u32, 56), calc_size.height);
    }

    // Case 2: Only rows specified
    {
        const image = Image{ .id = 2, .width = 16, .height = 9 };
        var placement = ImageStorage.Placement{
            .location = .{ .virtual = {} },
            .columns = 0,
            .rows = 5,
        };

        // Image is 16x9, set to a height of 5 rows, at 20px per row that's
        // 100px height. 100px * (16 / 9) = 177.77..., which should round to
        // a width of 178px.

        const calc_size = placement.pixelSize(image, &t);
        try testing.expectEqual(@as(u32, 178), calc_size.width);
        try testing.expectEqual(@as(u32, 100), calc_size.height);
    }
}

test "storage: default source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 5, .rows = 5 });
    defer t.deinit(alloc);

    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 3,
        .source_y = 1,
    };
    const actual = placement.pixelSize(.{ .width = 4, .height = 3 }, &t);
    try testing.expectEqual(@as(u32, 1), actual.width);
    try testing.expectEqual(@as(u32, 2), actual.height);
}

test "storage: explicit source rectangle is intersected before sizing" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    // The requested 8x8 rectangle intersects this 10x10 image as 2x3.
    // With a two-column destination, the clipped 2:3 aspect ratio produces
    // a 20x30 pixel destination.
    const placement: ImageStorage.Placement = .{
        .location = .{ .virtual = {} },
        .source_x = 8,
        .source_y = 7,
        .source_width = 8,
        .source_height = 8,
        .columns = 2,
    };
    const actual = placement.pixelSize(.{ .width = 10, .height = 10 }, &t);
    try testing.expectEqual(@as(u32, 20), actual.width);
    try testing.expectEqual(@as(u32, 30), actual.height);
}

test "storage: placement geometry handles untrusted dimensions" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    const max = std.math.maxInt(u32);

    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 2, .rows = 2 });
    defer t.deinit(alloc);
    t.width_px = max;
    t.height_px = max;

    // Cell dimensions multiplied by protocol-controlled row and column
    // counts saturate instead of panicking or wrapping.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .rows = 3,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }

    // Aspect-ratio scaling also saturates when the derived dimension does
    // not fit in the public u32 geometry type.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .columns = 3,
            .source_height = max,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .rows = 3,
            .source_width = max,
        };
        const actual = placement.pixelSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(max, actual.width);
        try testing.expectEqual(max, actual.height);
    }

    // Pixel offsets are protocol-controlled too. Clamp them to the cell
    // before including them in grid geometry.
    t.width_px = 2;
    t.height_px = 2;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .virtual = {} },
            .x_offset = max,
            .y_offset = max,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 1), actual.cols);
        try testing.expectEqual(@as(u32, 1), actual.rows);
    }

    const pin = try trackPin(&t, .{ .x = 0, .y = 0 });
    defer t.screens.active.pages.untrackPin(pin);

    // Explicit maximum dimensions must clamp the rectangle to the terminal
    // without overflowing its horizontal extent.
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = max,
            .rows = 1,
        };
        const rect = placement.rect(.{ .width = 1, .height = 1 }, &t).?;
        try testing.expectEqual(@as(size.CellCountInt, 1), rect.bottom_right.x);
    }

    // A garbage pin represents content that has been pruned from retained
    // history. Its fallback location must not make the placement visible.
    pin.garbage = true;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
            .rows = 1,
        };
        try testing.expect(placement.rect(.{ .width = 1, .height = 1 }, &t) == null);
    }
    pin.garbage = false;

    // Terminals can temporarily have no pixel geometry. A placement whose
    // computed grid is empty has no rectangle, so rect must not subtract one
    // from a zero row count.
    t.width_px = 0;
    t.height_px = 0;
    {
        const placement: ImageStorage.Placement = .{
            .location = .{ .pin = pin },
            .columns = 1,
        };
        const actual = placement.gridSize(.{ .width = 1, .height = 1 }, &t);
        try testing.expectEqual(@as(u32, 0), actual.cols);
        try testing.expectEqual(@as(u32, 0), actual.rows);
        try testing.expect(placement.rect(.{ .width = 1, .height = 1 }, &t) == null);
    }
}

test "storage: generation stamps on image add and replace" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Fresh storage has generation zero (never mutated).
    try testing.expectEqual(@as(u64, 0), s.generation);

    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen1 = s.generation;
    try testing.expect(gen1 > 0);

    const img1 = s.imageById(1).?;
    try testing.expectEqual(gen1, img1.generation);

    // A second image gets a strictly greater stamp.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .width = 1, .height = 1 });
    const gen2 = s.generation;
    try testing.expect(gen2 > gen1);
    try testing.expectEqual(gen2, s.imageById(2).?.generation);

    // Retransmitting the same image ID (identical dimensions) gets a
    // fresh stamp: this is what makes same-sized retransmissions
    // detectable by renderers.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .width = 1, .height = 1 });
    const gen3 = s.generation;
    try testing.expect(gen3 > gen2);
    try testing.expectEqual(gen3, s.imageById(1).?.generation);

    // Image 2 kept its stamp.
    try testing.expectEqual(gen2, s.imageById(2).?.generation);
}

test "storage: generation bumps on placement and delete" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    const gen_add = s.generation;

    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen_place = s.generation;
    try testing.expect(gen_place > gen_add);

    // Reads don't change the generation.
    _ = s.imageById(1);
    _ = s.imageByNumber(1);
    try testing.expectEqual(gen_place, s.generation);

    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(s.generation > gen_place);
}

test "storage: generation bumps when setLimit evicts or disables" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    const data = try alloc.dupe(u8, "1234");
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .data = .{ .complete = data },
    });
    const gen_add = s.generation;

    // Lowering the limit evicts the image and must mark a mutation.
    s.dirty = false;
    s.setLimit(io, alloc, t.screens.active, 1);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_add);
    try testing.expectEqual(@as(usize, 0), s.images.count());
    const gen_evict = s.generation;

    // Disabling (limit=0) resets the storage and must mark a mutation.
    s.dirty = false;
    s.setLimit(io, alloc, t.screens.active, 0);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen_evict);
}

test "storage: imageByNumber returns most recently transmitted" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Two images sharing a number: the newest transmission wins,
    // regardless of insertion order or clock resolution.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2, .number = 7 });
    try testing.expectEqual(@as(u32, 2), s.imageByNumber(7).?.id);

    // Retransmit the first: it becomes the newest.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1, .number = 7 });
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);
}

test "storage: nextGeneration is unique and monotonic" {
    const testing = std.testing;
    const a = nextGeneration(testing.io);
    const b = nextGeneration(testing.io);
    try testing.expect(b > a);
    try testing.expect(a > 0);
}

test "storage: no-op delete does not mark a mutation" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A delete-all on an empty storage (this runs on every screen
    // clear) must not dirty the state or bump the generation.
    s.delete(io, alloc, &t, .{ .all = true });
    try testing.expect(!s.dirty);
    try testing.expectEqual(@as(u64, 0), s.generation);

    // Same for a delete that matches nothing.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } });
    const gen = s.generation;
    s.dirty = false;
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 42 } });
    try testing.expect(!s.dirty);
    try testing.expectEqual(gen, s.generation);

    // But a delete that removes something does mark a mutation.
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 1 } });
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
}

test "storage: evicts images in priority order" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);

    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = false },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addPlacement(
        io,
        alloc,
        t.screens.active,
        2,
        1,
        .{ .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) } },
    );

    const gen = s.generation;
    const result = s.evictImage(io, alloc, t.screens.active, 96);
    try testing.expect(s.dirty);
    try testing.expect(s.generation > gen);
    try testing.expectEqual(true, result);
    try testing.expectEqual(1, s.images.count());
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
}

test "storage: eviction releases placement pins" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 128 };
    defer s.deinit(alloc, t.screens.active);

    const tracked = t.screens.active.pages.countTrackedPins();
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(tracked + 2, t.screens.active.pages.countTrackedPins());

    // Adding a third image evicts the oldest equally-ranked image and its
    // placement. The newer image's placement and tracked pin remain intact.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
    });
    try testing.expect(!s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(s.images.contains(3));
    try testing.expectEqual(@as(usize, 1), s.placements.count());
    try testing.expect(s.placements.contains(.{
        .image_id = 2,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(tracked + 1, t.screens.active.pages.countTrackedPins());
}

test "storage: pending image completes once and preserves age" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 16 };
    defer s.deinit(alloc, t.screens.active);

    const pending = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .number = 7,
        .width = 2,
        .height = 2,
        .format = .rgba,
        .data = .{ .pending = 16 },
    });
    try testing.expectEqual(@as(usize, 16), s.total_bytes);
    try testing.expectEqual(@as(u32, 1), s.imageByNumber(7).?.id);
    try testing.expect(s.imageById(1).?.data.isPending());

    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try testing.expectEqual(@as(usize, 1), s.placements.count());

    const wrong = try alloc.dupe(u8, "short");
    const wrong_completed = pending.complete(&s, io, wrong);
    try testing.expect(!wrong_completed);
    defer alloc.free(wrong);

    const storage_generation = s.generation;
    s.dirty = false;
    const pixels = try alloc.dupe(u8, "*" ** 16);
    try testing.expect(pending.complete(&s, io, pixels));
    try testing.expect(s.dirty);
    try testing.expect(s.generation > storage_generation);
    try testing.expectEqual(pending.generation, s.imageById(1).?.generation);
    try testing.expectEqual(@as(usize, 16), s.total_bytes);
    try testing.expectEqualSlices(u8, pixels, s.imageById(1).?.data.bytes().?);

    const duplicate = try alloc.dupe(u8, "!" ** 16);
    const duplicate_completed = pending.complete(&s, io, duplicate);
    try testing.expect(!duplicate_completed);
    defer alloc.free(duplicate);
}

test "storage: stale pending completion loses to delete replacement and eviction" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 8 };
    defer s.deinit(alloc, t.screens.active);

    const deleted = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .pending = 4 },
    });
    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 1 } });
    const deleted_data = try alloc.dupe(u8, "gone");
    const deleted_completed = deleted.complete(&s, io, deleted_data);
    try testing.expect(!deleted_completed);
    defer alloc.free(deleted_data);

    const replaced = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .pending = 4 },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "live") },
    });
    const replaced_data = try alloc.dupe(u8, "late");
    const replaced_completed = replaced.complete(&s, io, replaced_data);
    try testing.expect(!replaced_completed);
    defer alloc.free(replaced_data);
    try testing.expectEqualStrings("live", s.imageById(2).?.data.bytes().?);

    const evicted = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .pending = 4 },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 4,
        .data = .{ .complete = try alloc.dupe(u8, "12345678") },
    });
    try testing.expect(s.imageById(3) == null);
    const evicted_data = try alloc.dupe(u8, "late");
    const evicted_completed = evicted.complete(&s, io, evicted_data);
    try testing.expect(!evicted_completed);
    defer alloc.free(evicted_data);
}

test "storage: replacement reuses pending reservation and removes placements" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 12 };
    defer s.deinit(alloc, t.screens.active);
    const tracked = t.screens.active.pages.countTrackedPins();

    const pending = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .format = .rgba,
        .data = .{ .pending = 8 },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .complete = try alloc.dupe(u8, "keep") },
    });

    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, "12345678") },
    });
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(tracked, t.screens.active.pages.countTrackedPins());
    try testing.expectEqual(
        @as(u30, 0),
        s.imageById(1).?.metadata.placement_count,
    );
    try testing.expectEqual(@as(usize, 12), s.total_bytes);

    const stale = try alloc.dupe(u8, "snapshot");
    const stale_completed = pending.complete(&s, io, stale);
    try testing.expect(!stale_completed);
    defer alloc.free(stale);

    // Growing the replacement requires eviction, but the replacement ID is
    // excluded. The other image supplies the needed bytes.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .complete = try alloc.dupe(u8, "1234567890") },
    });
    try testing.expect(s.images.contains(1));
    try testing.expect(!s.images.contains(2));
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expectEqual(@as(usize, 10), s.total_bytes);

    s.delete(io, alloc, &t, .{ .id = .{ .delete = true, .image_id = 1 } });
    try testing.expectEqual(@as(usize, 0), s.images.count());
    try testing.expectEqual(@as(usize, 0), s.placements.count());
}

test "storage: pending images share exact eviction ordering" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{ .total_limit = 192 };
    defer s.deinit(alloc, t.screens.active);

    _ = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 1,
        .data = .{ .pending = 64 },
        .metadata = .{ .transient = false },
    });
    _ = try s.addPendingImage(io, alloc, t.screens.active, .{
        .id = 2,
        .data = .{ .pending = 64 },
        .metadata = .{ .transient = true },
    });
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .data = .{ .complete = try alloc.dupe(u8, "*" ** 64) },
        .metadata = .{ .transient = true },
    });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });

    // ID 3 is transient and unused, so one exact-size eviction is enough.
    try testing.expect(s.evictImage(io, alloc, t.screens.active, 64));
    try testing.expect(s.images.contains(1));
    try testing.expect(s.images.contains(2));
    try testing.expect(!s.images.contains(3));
    try testing.expectEqual(@as(usize, 128), s.total_bytes);
}

test "storage: nextImageId number matches Kitty get_free_client_id" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // Empty storage returns 1, as does Kitty.
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.explicit));

    // Contiguous IDs from 1: the next ID after them.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 3 });
    try testing.expectEqual(@as(u32, 4), s.nextImageId(.explicit));

    // The first gap is filled, even when higher IDs exist.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 100 });
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 2, .delete = true } });
    try testing.expectEqual(@as(u32, 2), s.nextImageId(.explicit));

    // 1 is reused as soon as it is free.
    s.delete(io, alloc, &t, .{ .id = .{ .image_id = 1, .delete = true } });
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.explicit));
}

test "storage: nextImageId implicit skips in-use ids and zero" {
    const testing = std.testing;
    const io = testing.io;
    const alloc = testing.allocator;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 3, .cols = 3 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A client image already sits on the counter's first two values.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2147483647 });
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2147483648 });
    try testing.expectEqual(@as(u32, 2147483649), s.nextImageId(.implicit));
    try testing.expectEqual(@as(u32, 2147483650), s.nextImageId(.implicit));

    // Wrapping skips zero, which means "no ID" protocol-wide.
    s.next_image_id = std.math.maxInt(u32);
    try testing.expectEqual(std.math.maxInt(u32), s.nextImageId(.implicit));
    try testing.expectEqual(@as(u32, 1), s.nextImageId(.implicit));
}

test "storage: scroll margins placement inside region scrolls and clips at top" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image (10x10px cells) inside the region (rows 1-4).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);

    // Entirely inside: moves up with the content.
    try t.index();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
    }

    // Would extend above the top margin: anchored at the top margin
    // with the top cell row clipped off the source.
    try t.index();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
        try testing.expectEqual(@as(u32, 10), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }

    // Fully clipped: deleted.
    try t.index();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
    // The image itself is retained.
    try testing.expectEqual(@as(usize, 1), storage.images.count());
}

test "storage: scroll margins placement straddling region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 3-row image anchored at the top of a 2-row region: not entirely
    // within the region, so region scrolls must not move it. This
    // exercises the scrollback-creating path (region top at row 0).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 30,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setTopAndBottomMargin(1, 2);
    t.setCursorPos(2, 1);

    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}

test "storage: scroll margins placement below region does not move" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // A "status bar" image below the bottom margin must stay put while
    // the region above it scrolls (scrollback-creating path).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 5 }) },
    });
    t.setTopAndBottomMargin(1, 4);
    t.setCursorPos(4, 1);

    try t.index();
    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 5 }, pt.coord());
}

test "storage: scroll margins reverse index clips at bottom" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image at the bottom of the region (rows 1-4).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 3 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);

    // Moves down, with the bottom cell row clipped off the source.
    t.reverseIndex();
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 4 }, pt.coord());
        try testing.expectEqual(@as(u32, 0), p.source_y);
        try testing.expectEqual(@as(u32, 10), p.source_height);
    }

    // Fully clipped: deleted.
    t.reverseIndex();
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "storage: scroll margins scaled placement clips proportionally" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // A 40px-tall image scaled into 2 rows, inside a 2-row region.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 40,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 1 }) },
        .columns = 1,
        .rows = 2,
    });
    t.setTopAndBottomMargin(2, 3);
    t.setCursorPos(3, 1);

    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 1 }, pt.coord());
    try testing.expectEqual(@as(u32, 20), p.source_y);
    try testing.expectEqual(@as(u32, 20), p.source_height);
    try testing.expectEqual(@as(u32, 1), p.rows);
    try testing.expectEqual(@as(u32, 1), p.columns);
}

test "storage: scroll margins left/right margins respect columns" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // One placement outside the left/right margin columns, one inside.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 2, .y = 2 }) },
    });

    t.modes.set(.enable_left_and_right_margin, true);
    t.setLeftAndRightMargin(2, 8);

    try t.scrollUp(1);

    // Outside the margin columns: stays.
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }

    // Inside: moves up.
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 2 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 2, .y = 1 }, pt.coord());
    }
}

test "storage: scroll margins insert/delete lines do not move placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // Kitty does not scroll images for IL/DL, only for IND/RI/SU/SD.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(2, 1);

    t.deleteLines(1);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }

    t.insertLines(1);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 2 }, pt.coord());
    }
}

test "storage: scroll without margins moves placement into scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // No margins: the placement follows its anchored row into the
    // scrollback via pin tracking (kitty's marginless behavior).
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    t.setCursorPos(6, 1);

    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    try testing.expect(t.screens.active.pages.pointFromPin(
        .active,
        p.location.pin.*,
    ) == null);
    const pt = t.screens.active.pages.pointFromPin(.screen, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
}

test "storage: scroll margins large scroll deletes inside placement" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(2, 5);

    try t.scrollUp(10);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "storage: scroll margins straddling placement pin inside region restored" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 2-row image anchored on the bottom margin row, extending below
    // the region: not entirely inside, so it must not move even though
    // the region scroll moves every tracked pin within the region rows.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 20,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 4 }) },
    });
    t.setTopAndBottomMargin(2, 5);
    t.setCursorPos(5, 1);

    try t.index();
    const p = storage.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }).?;
    const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
    try testing.expectEqual(point.Coordinate{ .x = 0, .y = 4 }, pt.coord());
    try testing.expectEqual(@as(u32, 0), p.source_y);
    try testing.expectEqual(@as(u32, 0), p.source_height);
}

test "storage: scroll margins multi-line scroll up with scrollback" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 6 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 60;

    // 1-row image inside a region whose top is the screen top, so the
    // scroll pushes text into the scrollback (window shift) while the
    // image moves within the region.
    const storage: *ImageStorage = &t.screens.active.kitty_images;
    try storage.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 10,
        .height = 10,
    });
    try storage.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 2 }) },
    });
    t.setTopAndBottomMargin(1, 4);

    try t.scrollUp(2);
    {
        const p = storage.placements.get(.{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        }).?;
        const pt = t.screens.active.pages.pointFromPin(.active, p.location.pin.*).?;
        try testing.expectEqual(point.Coordinate{ .x = 0, .y = 0 }, pt.coord());
    }

    // Another two rows scrolls it out of the region: deleted.
    try t.scrollUp(2);
    try testing.expectEqual(@as(usize, 0), storage.placements.count());
}

test "storage: resolveChain accumulates offsets to the pin root" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 2,
            .vertical_offset = 1,
        } },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 2 },
            },
            .horizontal_offset = -1,
            .vertical_offset = 4,
        } },
    });

    const grandchild = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 3 },
    }).?;
    const chain = s.resolveChain(grandchild.location.relative).?;
    try testing.expect(chain.root_key.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expect(chain.root.location == .pin);
    try testing.expectEqual(@as(i32, 1), chain.horizontal_offset);
    try testing.expectEqual(@as(i32, 5), chain.vertical_offset);
}

test "storage: resolveChain finds virtual roots" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .virtual = {} },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 2, .{
        .location = .{ .relative = .{
            .parent = .{
                .image_id = 1,
                .placement_id = .{ .tag = .external, .id = 1 },
            },
            .horizontal_offset = 1,
        } },
    });

    const child = s.placements.get(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 2 },
    }).?;
    const chain = s.resolveChain(child.location.relative).?;
    try testing.expect(chain.root.location == .virtual);
    try testing.expect(chain.root_key.eql(.{
        .image_id = 1,
        .placement_id = .{ .tag = .external, .id = 1 },
    }));
    try testing.expectEqual(@as(i32, 1), chain.horizontal_offset);
    try testing.expectEqual(@as(i32, 0), chain.vertical_offset);
}

test "storage: eviction removes orphaned relative placements" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    s.total_limit = 8;

    // Image 1 holds most of the byte budget and has a pin placement.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 2,
        .height = 1,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 0, 0, 0, 0, 0, 0 }) },
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 1, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 1, .y = 1 }) },
    });

    // Image 2's placement is relative to image 1's placement.
    try s.addImage(io, alloc, t.screens.active, .{ .id = 2 });
    try s.addPlacement(io, alloc, t.screens.active, 2, 1, .{
        .location = .{ .relative = .{ .parent = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 1 },
        } } },
    });

    // Adding image 3 exceeds the limit and evicts image 1 (oldest),
    // removing its placement, which orphans image 2's placement.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 3,
        .width = 2,
        .height = 1,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 0, 0, 0, 0, 0, 0 }) },
    });

    try testing.expect(s.imageById(1) == null);
    try testing.expectEqual(@as(usize, 0), s.placements.count());
    try testing.expect(s.imageById(2) != null);
}

test "storage: placeholderTarget lookup" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .rows = 5, .cols = 5 });
    defer t.deinit(alloc);

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);
    try s.addImage(io, alloc, t.screens.active, .{ .id = 1 });
    try s.addPlacement(io, alloc, t.screens.active, 1, 5, .{
        .location = .{ .virtual = {} },
    });

    // Exact external ID match.
    {
        const target = s.placeholderTarget(1, 5).?;
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 5 },
        };
        try testing.expectEqual(expected, target.key);
        try testing.expect(target.placement.location == .virtual);
    }

    // Zero placement ID falls back to the image's virtual placement.
    {
        const target = s.placeholderTarget(1, 0).?;
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 5 },
        };
        try testing.expectEqual(expected, target.key);
    }

    try testing.expect(s.placeholderTarget(1, 9) == null);
    try testing.expect(s.placeholderTarget(2, 0) == null);

    // With multiple virtual placements, the zero-ID fallback picks
    // deterministically by PlacementId.preferredOver: lowest external.
    try s.addPlacement(io, alloc, t.screens.active, 1, 3, .{
        .location = .{ .virtual = {} },
    });
    {
        const expected: ImageStorage.PlacementKey = .{
            .image_id = 1,
            .placement_id = .{ .tag = .external, .id = 3 },
        };
        try testing.expectEqual(expected, s.placeholderTarget(1, 0).?.key);
    }
}

test "storage: animation tick advances and schedules" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A running 1x1 RGBA image whose animation has one extra frame.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const img = s.images.getPtr(1).?;
    const anim = try alloc.create(animation.Animation);
    anim.* = .{ .state = .running };
    img.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });

    // Without a placement the animation doesn't advance (our
    // approximation of Kitty's visibility gate).
    try testing.expect(s.animationTick(io, 0) == null);
    try testing.expectEqual(@as(u32, 0), anim.current_index);

    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });
    const gen1 = img.generation;
    s.dirty = false;

    // First tick: the gapless root frame is due immediately and is
    // skipped over to frame 2, which is due again in its 40ms gap.
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(img.generation > gen1);
    try testing.expect(s.dirty);

    // Nothing due yet: no advance, and the delay counts down.
    const gen2 = img.generation;
    try testing.expectEqual(@as(?u64, 30), s.animationTick(io, 10));
    try testing.expectEqual(gen2, img.generation);

    // Wrapping is fine with an infinite loop budget: the gapless
    // root is skipped and frame 2 is shown again.
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 40));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(@as(u32, 1), anim.current_loop);
}

test "storage: animation tick loading state parks on last frame" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A placed 1x1 RGBA image in the loading state (a=a s=2) whose
    // animation has one extra frame.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{ .state = .loading };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });

    // Reach the last frame, then park: no wakeup is scheduled while
    // waiting for more frames and the loop counter stays untouched.
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 100) == null);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expectEqual(@as(u32, 0), anim.current_loop);

    // A new frame arriving un-parks playback.
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 255, 0, 255 }),
        .gap_ms = 25,
    });
    try testing.expectEqual(@as(?u64, 25), s.animationTick(io, 150));
    try testing.expectEqual(@as(u32, 2), anim.current_index);
}

test "storage: animation tick exhausts loop budget" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A placed, running 1x1 RGBA image with a gapped root frame, one
    // extra frame, and a one-loop budget (a=a v=2).
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{
        .state = .running,
        .root_gap_ms = 10,
        .max_loops = 1,
    };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });

    // Root shows for 10ms, frame 2 for 40ms, then the wrap exhausts
    // the budget and playback freezes on the last frame for good.
    try testing.expectEqual(@as(?u64, 10), s.animationTick(io, 0));
    try testing.expectEqual(@as(u32, 0), anim.current_index);
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 10));
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 50) == null);
    try testing.expectEqual(@as(u32, 1), anim.current_index);
    try testing.expect(s.animationTick(io, 500) == null);
}

test "storage: animation tick ignores ineligible animations" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A placed 1x1 RGBA image with one extra frame, in the default
    // stopped state.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{};
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });

    // Stopped (the default) never advances.
    try testing.expect(s.animationTick(io, 0) == null);

    // An all-gapless animation can never advance either.
    anim.state = .running;
    anim.frames.items[0].gap_ms = 0;
    try testing.expect(s.animationTick(io, 0) == null);
    try testing.expectEqual(@as(u32, 0), anim.current_index);
}

test "storage: animation tick re-anchors a restarted clock" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const io = testing.io;
    var t = try terminal.Terminal.init(io, alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    t.width_px = 100;
    t.height_px = 100;

    var s: ImageStorage = .{};
    defer s.deinit(alloc, t.screens.active);

    // A placed, running 1x1 RGBA image displaying its extra frame,
    // with a shown-at timestamp far ahead of the tick clock.
    try s.addImage(io, alloc, t.screens.active, .{
        .id = 1,
        .width = 1,
        .height = 1,
        .format = .rgba,
        .data = .{ .complete = try alloc.dupe(u8, &.{ 255, 0, 0, 255 }) },
    });
    const anim = try alloc.create(animation.Animation);
    anim.* = .{
        .state = .running,
        .current_index = 1,
        .frame_shown_at_ms = 1000,
    };
    s.images.getPtr(1).?.animation = anim;
    try anim.frames.append(alloc, .{
        .data = try alloc.dupe(u8, &.{ 0, 0, 255, 255 }),
        .gap_ms = 40,
    });
    try s.addPlacement(io, alloc, t.screens.active, 1, 0, .{
        .location = .{ .pin = try trackPin(&t, .{ .x = 0, .y = 0 }) },
    });

    // A timestamp in the future relative to now means the caller's
    // clock restarted; the animation must not stall until the old
    // timestamp comes around again.
    try testing.expectEqual(@as(?u64, 40), s.animationTick(io, 5));
    try testing.expectEqual(@as(?u64, 5), anim.frame_shown_at_ms);
}
