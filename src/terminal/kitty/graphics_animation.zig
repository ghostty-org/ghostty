//! Kitty graphics protocol animation support.
//!
//! https://sw.kovidgoyal.net/kitty/graphics-protocol/#animation
//!
//! An animation is a set of frames attached to an existing image.
//! Frame 1 (the "root frame") is the image's own base data. Frames
//! 2..N are stored here. Unlike Kitty, which stores frames as delta
//! rectangles in a disk cache and composes them lazily, we compose
//! every frame eagerly into a full image-sized RGBA buffer at load
//! time. This trades some memory for a much simpler model: a frame is
//! always ready to display and there are no reference chains to
//! maintain, coalesce, or garbage collect. Frame storage is bounded
//! by the same byte limit as image storage.
//!
//! To keep composition to a single pixel format, an image is
//! converted to RGBA the first time an animation command composes
//! into it, and all transmitted frame data is converted to RGBA
//! before composition. Blending an opaque (alpha=255) source pixel
//! degenerates to a copy, so this loses no information relative to
//! Kitty's separate RGB/RGBA paths. The pixel-level primitives
//! (conversion, fill, rectangle composition) live in
//! graphics_pixel.zig.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The gap assigned to a newly created frame when the command doesn't
/// specify one (z omitted or z=0). Taken from Kitty (DEFAULT_GAP).
pub const default_gap_ms: u32 = 40;

/// Animation state for a single image. Heap-allocated and owned by
/// the Image. This is created lazily by the first animation command that
/// needs it.
pub const Animation = struct {
    /// The frames following the root frame: `frames.items[i]` is
    /// protocol frame number `i + 2`. The root frame (frame 1) is the
    /// image's base data and is not stored here.
    frames: std.ArrayListUnmanaged(Frame) = .empty,

    /// The gap of the root frame in milliseconds. Zero means gapless:
    /// the frame is skipped during playback. Kitty creates the root
    /// frame with a zero gap; the client gives it one with a=a,r=1,z=N.
    root_gap_ms: u32 = 0,

    /// The zero-based index of the frame currently displayed: 0 is
    /// the root frame, i >= 1 is frames.items[i - 1].
    current_index: u32 = 0,

    /// Playback state. Every image starts stopped (client-driven).
    state: State = .stopped,

    /// Maximum number of loops to play (0 = infinite). Set from the
    /// a=a v key as v-1, per the protocol's off-by-one encoding.
    max_loops: u32 = 0,

    /// Number of completed loops since playback started.
    current_loop: u32 = 0,

    /// Timestamp in milliseconds (on the ticker's clock, see
    /// ImageStorage.animationTick) when the current frame was shown.
    /// Null means "not yet shown"; the next tick stamps it.
    frame_shown_at_ms: ?u64 = null,

    pub const State = enum {
        /// Not advancing; frames change only via a=a c=N (client-driven).
        stopped,
        /// Advancing, but playback parks on the last frame waiting
        /// for more frames instead of looping (a=a s=2).
        loading,
        /// Advancing and looping (a=a s=3).
        running,
    };

    pub const Frame = struct {
        /// Fully composed pixel data, always image width * height * 4
        /// bytes of RGBA.
        data: []u8,

        /// Milliseconds this frame is displayed before advancing.
        /// Zero means gapless: skipped during playback.
        gap_ms: u32,
    };

    pub fn deinit(self: *Animation, alloc: Allocator) void {
        for (self.frames.items) |frame| alloc.free(frame.data);
        self.frames.deinit(alloc);
    }

    /// The total number of frames including the root frame.
    pub fn frameCount(self: *const Animation) u32 {
        return @intCast(self.frames.items.len + 1);
    }

    /// The gap of the frame at the given zero-based index.
    pub fn gapAt(self: *const Animation, index: u32) u32 {
        if (index == 0) return self.root_gap_ms;
        return self.frames.items[index - 1].gap_ms;
    }

    /// Set the gap of the frame at the given zero-based index.
    pub fn setGapAt(self: *Animation, index: u32, gap_ms: u32) void {
        if (index == 0) {
            self.root_gap_ms = gap_ms;
        } else {
            self.frames.items[index - 1].gap_ms = gap_ms;
        }
    }

    /// The sum of all frame gaps. An animation with a zero duration
    /// (every frame gapless) never advances; this doubles as the
    /// guard that keeps the gapless-skip loop in animationTick from
    /// spinning forever, exactly like Kitty's animation_duration.
    pub fn durationMs(self: *const Animation) u64 {
        var total: u64 = self.root_gap_ms;
        for (self.frames.items) |frame| total += frame.gap_ms;
        return total;
    }

    /// Bytes of frame data held by this animation, counted against
    /// the image storage limit.
    pub fn frameBytes(self: *const Animation) usize {
        var total: usize = 0;
        for (self.frames.items) |frame| total += frame.data.len;
        return total;
    }
};

test "animation gap helpers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var anim: Animation = .{};
    defer anim.deinit(alloc);
    try anim.frames.append(alloc, .{
        .data = try alloc.alloc(u8, 4),
        .gap_ms = 100,
    });

    try testing.expectEqual(@as(u32, 2), anim.frameCount());
    try testing.expectEqual(@as(u32, 0), anim.gapAt(0));
    try testing.expectEqual(@as(u32, 100), anim.gapAt(1));
    try testing.expectEqual(@as(u64, 100), anim.durationMs());
    try testing.expectEqual(@as(usize, 4), anim.frameBytes());

    anim.setGapAt(0, 40);
    anim.setGapAt(1, 60);
    try testing.expectEqual(@as(u64, 100), anim.durationMs());
    try testing.expectEqual(@as(u32, 40), anim.root_gap_ms);
}
