//! Per-session storage for Glyph Protocol registrations.
//!
//! Holds at most `capacity` registrations keyed by codepoint. On the
//! (capacity+1)-th register for a fresh codepoint, the oldest entry is
//! evicted (FIFO) to make room, per spec §4. Overwriting an existing
//! codepoint replaces its outline but preserves both its stable slot
//! index (used as an atlas cache key) and its position in insertion
//! order. Insertion order comes for free from the array-hash-map
//! backing — `keys()[0]` is always the next eviction candidate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const glyf = @import("glyf.zig");
const request = @import("request.zig");

/// Stored payload for a registration.
pub const Payload = request.DecodedPayload;

/// Authoritative cell width for a registered codepoint.
pub const Width = request.Width;

/// Maximum simultaneous registrations per session (spec §4).
pub const capacity: usize = 1024;

/// A single registered glyph.
pub const Entry = struct {
    payload: Payload,
    /// Units-per-em the outline was authored in.
    upm: u16,
    /// Authoritative wcwidth for the codepoint.
    width: Width,
    /// Stable slot index in `0..capacity`.
    slot: u16,
};

/// Per-session glyph-protocol glossary. `Terminal` owns one of these.
pub const Glossary = struct {
    /// Insertion-ordered map. `keys()[0]` is the oldest entry (next
    /// FIFO eviction candidate); `put` on an existing key preserves
    /// the entry's position.
    by_cp: std.AutoArrayHashMapUnmanaged(u21, Entry) = .empty,
    /// Reverse index: `slots[i]` is the codepoint currently using slot
    /// `i`, or `null` if the slot is free.
    slots: [capacity]?u21 = [_]?u21{null} ** capacity,
    /// Incremented on every mutation (register, clearOne, clearAll).
    /// Consumers (e.g. the renderer) compare their last-seen value to
    /// detect when they need to resync their snapshot of the glossary.
    mutation_count: u64 = 0,

    pub fn deinit(self: *Glossary, alloc: Allocator) void {
        for (self.by_cp.values()) |*entry| entry.payload.deinit(alloc);
        self.by_cp.deinit(alloc);
        self.* = undefined;
    }

    pub fn contains(self: *const Glossary, cp: u21) bool {
        return self.by_cp.contains(cp);
    }

    pub fn get(self: *const Glossary, cp: u21) ?*const Entry {
        return self.by_cp.getPtr(cp);
    }

    pub fn len(self: *const Glossary) usize {
        return self.by_cp.count();
    }

    /// Register a payload for `cp`. Ownership of `payload` transfers to
    /// the glossary on success; on error the caller still owns it and
    /// must deinit.
    ///
    /// On overwrite, the existing slot and insertion order are preserved
    /// (eviction ordering is unaffected) and the previous payload is
    /// freed. On a fresh registration with the glossary full, the oldest
    /// entry is evicted. The evicted codepoint is returned so callers
    /// can invalidate any atlas entry keyed on it.
    pub fn register(
        self: *Glossary,
        alloc: Allocator,
        cp: u21,
        payload: Payload,
        upm: u16,
        width: Width,
    ) Allocator.Error!?u21 {
        self.mutation_count +%= 1;

        if (self.by_cp.getPtr(cp)) |existing| {
            var old = existing.payload;
            existing.payload = payload;
            existing.upm = upm;
            existing.width = width;
            old.deinit(alloc);
            return null;
        }

        var evicted: ?u21 = null;
        var slot: u16 = undefined;
        if (self.findFreeSlot()) |free| {
            slot = free;
        } else {
            const oldest_cp = self.by_cp.keys()[0];
            const entry = self.by_cp.fetchOrderedRemove(oldest_cp).?.value;
            slot = entry.slot;
            self.slots[slot] = null;
            var evicted_payload = entry.payload;
            evicted_payload.deinit(alloc);
            evicted = oldest_cp;
        }

        // Allocate the new entry before touching `slots`, so an
        // allocation failure leaves the glossary consistent.
        try self.by_cp.put(alloc, cp, .{
            .payload = payload,
            .upm = upm,
            .width = width,
            .slot = slot,
        });
        self.slots[slot] = cp;
        return evicted;
    }

    /// Authoritative width for a registered codepoint, or `null` when
    /// the codepoint isn't registered.
    pub fn widthFor(self: *const Glossary, cp: u21) ?Width {
        const entry = self.by_cp.getPtr(cp) orelse return null;
        return entry.width;
    }

    /// Drop the registration for `cp`. No-op if nothing was registered.
    pub fn clearOne(self: *Glossary, alloc: Allocator, cp: u21) void {
        if (self.by_cp.fetchOrderedRemove(cp)) |kv| {
            self.mutation_count +%= 1;
            self.slots[kv.value.slot] = null;
            var payload = kv.value.payload;
            payload.deinit(alloc);
        }
    }

    /// Drop every registration and free every slot.
    pub fn clearAll(self: *Glossary, alloc: Allocator) void {
        if (self.by_cp.count() == 0) return;
        self.mutation_count +%= 1;
        for (self.by_cp.values()) |*entry| entry.payload.deinit(alloc);
        self.by_cp.clearRetainingCapacity();
        self.slots = [_]?u21{null} ** capacity;
    }

    /// Recover the codepoint currently occupying `slot`, if any.
    pub fn cpForSlot(self: *const Glossary, slot: u16) ?u21 {
        if (slot >= capacity) return null;
        return self.slots[slot];
    }

    fn findFreeSlot(self: *const Glossary) ?u16 {
        for (self.slots, 0..) |s, i| if (s == null) return @intCast(i);
        return null;
    }
};

const testing = std.testing;

/// Synthesize a minimal but valid `Payload` whose bounding box x_min is
/// `marker`, so tests can distinguish which outline ended up where.
fn markerOutline(marker: i32) Payload {
    return .{ .glyf = .{
        .contours = &.{},
        .points = &.{},
        .x_min = marker,
        .y_min = 0,
        .x_max = 0,
        .y_max = 0,
    } };
}

test "register and get" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    const evicted = try g.register(testing.allocator, 0xE0A0, markerOutline(42), 1000, .narrow);
    try testing.expect(evicted == null);
    try testing.expect(g.contains(0xE0A0));
    try testing.expectEqual(@as(i32, 42), g.get(0xE0A0).?.payload.glyf.x_min);
    try testing.expectEqual(@as(u16, 1000), g.get(0xE0A0).?.upm);
    try testing.expectEqual(Width.narrow, g.get(0xE0A0).?.width);
    try testing.expectEqual(@as(usize, 1), g.len());
}

test "register stores wide width and widthFor reports it" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .wide);
    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(0), 1000, .narrow);

    try testing.expectEqual(Width.wide, g.widthFor(0xE0A0).?);
    try testing.expectEqual(Width.narrow, g.widthFor(0xE0A1).?);
    try testing.expect(g.widthFor(0xE0A2) == null);
}

test "overwrite updates width" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    try testing.expectEqual(Width.narrow, g.widthFor(0xE0A0).?);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .wide);
    try testing.expectEqual(Width.wide, g.widthFor(0xE0A0).?);
}

test "overwrite preserves slot and insertion order" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(1), 1000, .narrow);
    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(2), 1000, .narrow);

    const slot_before = g.get(0xE0A0).?.slot;

    const evicted = try g.register(testing.allocator, 0xE0A0, markerOutline(9), 2048, .narrow);
    try testing.expect(evicted == null);

    const a = g.get(0xE0A0).?;
    try testing.expectEqual(@as(i32, 9), a.payload.glyf.x_min);
    try testing.expectEqual(@as(u16, 2048), a.upm);
    try testing.expectEqual(slot_before, a.slot);
    // Overwrite must keep the original ordering: 0xE0A0 still sits ahead
    // of 0xE0A1 in the eviction queue.
    try testing.expectEqual(@as(u21, 0xE0A0), g.by_cp.keys()[0]);
    try testing.expectEqual(@as(u21, 0xE0A1), g.by_cp.keys()[1]);
}

test "distinct registrations get distinct slots" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(0), 1000, .narrow);
    _ = try g.register(testing.allocator, 0xE0A2, markerOutline(0), 1000, .narrow);

    const s0 = g.get(0xE0A0).?.slot;
    const s1 = g.get(0xE0A1).?.slot;
    const s2 = g.get(0xE0A2).?.slot;
    try testing.expect(s0 != s1 and s1 != s2 and s0 != s2);
    try testing.expectEqual(@as(u21, 0xE0A0), g.cpForSlot(s0).?);
    try testing.expectEqual(@as(u21, 0xE0A1), g.cpForSlot(s1).?);
}

test "cleared slot is reused by next registration" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    const old_slot = g.get(0xE0A0).?.slot;
    g.clearOne(testing.allocator, 0xE0A0);
    try testing.expect(g.cpForSlot(old_slot) == null);

    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(0), 1000, .narrow);
    try testing.expectEqual(old_slot, g.get(0xE0A1).?.slot);
}

test "clearOne leaves others intact" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(0), 1000, .narrow);
    g.clearOne(testing.allocator, 0xE0A0);
    try testing.expect(!g.contains(0xE0A0));
    try testing.expect(g.contains(0xE0A1));
}

test "clearOne unknown cp is a no-op" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    g.clearOne(testing.allocator, 0xE0A0);
    try testing.expectEqual(@as(usize, 0), g.len());
}

test "clearAll drops everything" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    _ = try g.register(testing.allocator, 0xE0A1, markerOutline(0), 1000, .narrow);
    g.clearAll(testing.allocator);
    try testing.expectEqual(@as(usize, 0), g.len());
    try testing.expect(g.cpForSlot(0) == null);
}

test "FIFO eviction at capacity" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    // Fill with contiguous PUA codepoints.
    var i: u21 = 0;
    while (i < capacity) : (i += 1) {
        _ = try g.register(
            testing.allocator,
            @as(u21, 0xE000) + i,
            markerOutline(@intCast(i)),
            1000,
            .narrow,
        );
    }
    try testing.expectEqual(capacity, g.len());

    // Next fresh registration evicts U+E000 (the oldest).
    const evicted = try g.register(testing.allocator, 0xE500, markerOutline(-1), 1000, .narrow);
    try testing.expectEqual(@as(u21, 0xE000), evicted.?);
    try testing.expect(!g.contains(0xE000));
    try testing.expect(g.contains(0xE500));
    try testing.expectEqual(capacity, g.len());
}

test "mutation_count bumps on register, overwrite, clear" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);
    try testing.expectEqual(@as(u64, 0), g.mutation_count);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(0), 1000, .narrow);
    try testing.expectEqual(@as(u64, 1), g.mutation_count);

    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(1), 1000, .narrow); // overwrite
    try testing.expectEqual(@as(u64, 2), g.mutation_count);

    g.clearOne(testing.allocator, 0xE0A0);
    try testing.expectEqual(@as(u64, 3), g.mutation_count);

    // clearOne on empty doesn't bump.
    g.clearOne(testing.allocator, 0xE0A0);
    try testing.expectEqual(@as(u64, 3), g.mutation_count);

    // clearAll on empty doesn't bump; on non-empty, does.
    g.clearAll(testing.allocator);
    try testing.expectEqual(@as(u64, 3), g.mutation_count);
    _ = try g.register(testing.allocator, 0xE0A0, markerOutline(2), 1000, .narrow);
    g.clearAll(testing.allocator);
    try testing.expectEqual(@as(u64, 5), g.mutation_count);
}

test "overwrite at capacity does not evict" {
    var g: Glossary = .{};
    defer g.deinit(testing.allocator);

    var i: u21 = 0;
    while (i < capacity) : (i += 1) {
        _ = try g.register(
            testing.allocator,
            @as(u21, 0xE000) + i,
            markerOutline(@intCast(i)),
            1000,
            .narrow,
        );
    }
    const evicted = try g.register(testing.allocator, 0xE000, markerOutline(1234), 1000, .narrow);
    try testing.expect(evicted == null);
    try testing.expectEqual(capacity, g.len());
    try testing.expectEqual(@as(i32, 1234), g.get(0xE000).?.payload.glyf.x_min);
}
