//! Highlights are any contiguous sequences of cells that should
//! be called out in some way, most commonly for text selection but
//! also search results or any other purpose.
//!
//! Within the terminal package, a highlight is a generic concept
//! that represents a range of cells.

// NOTE: The plan is for highlights to ultimately replace Selection
// completely. Selection is deeply tied to various parts of the Ghostty
// internals so this may take some time.

const std = @import("std");
const Allocator = std.mem.Allocator;
const size = @import("size.zig");
const PageList = @import("PageList.zig");
const PageChunk = PageList.PageIterator.Chunk;
const Pin = PageList.Pin;
const Screen = @import("Screen.zig");

/// An untracked highlight is a highlight that stores its highlighted
/// area as a top-left and bottom-right screen pin. Since it is untracked,
/// the pins are only valid for the current terminal state and may not
/// be safe to use after any terminal modifications.
///
/// For rectangle highlights/selections, the downstream consumer of this
/// code is expected to interpret the pins in whatever shape they want.
/// For example, a rectangular selection would interpret the pins as
/// setting the x bounds for each row between start.y and end.y.
///
/// To simplify all operations, start MUST be before or equal to end.
pub const Untracked = struct {
    start: Pin,
    end: Pin,

    pub fn track(
        self: *const Untracked,
        screen: *Screen,
    ) Allocator.Error!Tracked {
        return try .init(
            screen,
            self.start,
            self.end,
        );
    }

    pub fn eql(self: Untracked, other: Untracked) bool {
        return self.start.eql(other.start) and self.end.eql(other.end);
    }
};

/// A tracked highlight is a highlight that stores its highlighted
/// area as tracked pins within a screen.
///
/// A tracked highlight ensures that the pins remain valid even as
/// the terminal state changes. Because of this, tracked highlights
/// have more operations available to them.
///
/// There is more overhead to creating and maintaining tracked highlights.
/// If you're manipulating highlights that are untracked and you're sure
/// that the terminal state won't change, you can use the `initAssume`
/// function.
pub const Tracked = struct {
    start: *Pin,
    end: *Pin,

    pub fn init(
        screen: *Screen,
        start: Pin,
        end: Pin,
    ) Allocator.Error!Tracked {
        const start_tracked = try screen.pages.trackPin(start);
        errdefer screen.pages.untrackPin(start_tracked);
        const end_tracked = try screen.pages.trackPin(end);
        errdefer screen.pages.untrackPin(end_tracked);
        return .{
            .start = start_tracked,
            .end = end_tracked,
        };
    }

    /// Initializes a tracked highlight by assuming that the provided
    /// pins are already tracked. This allows callers to perform tracked
    /// operations without the overhead of tracking the pins, if the
    /// caller can guarantee that the pins are already tracked or that
    /// the terminal state will not change.
    ///
    /// Do not call deinit on highlights created with this function.
    pub fn initAssume(
        start: *Pin,
        end: *Pin,
    ) Tracked {
        return .{
            .start = start,
            .end = end,
        };
    }

    pub fn deinit(
        self: Tracked,
        screen: *Screen,
    ) void {
        screen.pages.untrackPin(self.start);
        screen.pages.untrackPin(self.end);
    }
};

/// A flattened highlight is a highlight that stores its highlighted
/// area as a list of page chunks. This representation allows for
/// traversing the entire highlighted area without needing to read any
/// terminal state or dereference any page nodes (which may have been
/// pruned).
pub const Flattened = struct {
    /// The page chunks that make up this highlight. This handles the
    /// y bounds since chunks[0].start is the first highlighted row
    /// and chunks[len - 1].end is the last highlighted row (exclsive).
    chunks: std.MultiArrayList(Chunk),

    /// The x bounds of the highlight. `bot_x` may be less than `top_x`
    /// for typical left-to-right highlights: can start the selection right
    /// of the end on a higher row.
    top_x: size.CellCountInt,
    bot_x: size.CellCountInt,

    /// A flattened chunk is almost identical to a PageList.Chunk but
    /// we also flatten the serial number. This lets the flattened
    /// highlight more robust for comparisons and validity checks with
    /// the PageList.
    pub const Chunk = struct {
        node: *PageList.List.Node,
        serial: u64,
        start: size.CellCountInt,
        end: size.CellCountInt,
    };

    pub const empty: Flattened = .{
        .chunks = .empty,
        .top_x = 0,
        .bot_x = 0,
    };

    pub fn init(
        alloc: Allocator,
        start: Pin,
        end: Pin,
    ) Allocator.Error!Flattened {
        var result: std.MultiArrayList(PageChunk) = .empty;
        errdefer result.deinit(alloc);
        var it = start.pageIterator(.right_down, end);
        while (it.next()) |chunk| try result.append(alloc, .{
            .node = chunk.node,
            .serial = chunk.node.serial,
            .start = chunk.start,
            .end = chunk.end,
        });
        return .{
            .chunks = result,
            .top_x = start.x,
            .end_x = end.x,
        };
    }

    pub fn deinit(self: *Flattened, alloc: Allocator) void {
        self.chunks.deinit(alloc);
    }

    pub fn clone(self: *const Flattened, alloc: Allocator) Allocator.Error!Flattened {
        return .{
            .chunks = try self.chunks.clone(alloc),
            .top_x = self.top_x,
            .bot_x = self.bot_x,
        };
    }

    pub fn startPin(self: Flattened) Pin {
        const slice = self.chunks.slice();
        return .{
            .node = slice.items(.node)[0],
            .x = self.top_x,
            .y = slice.items(.start)[0],
        };
    }

    pub fn endPin(self: Flattened) Pin {
        const slice = self.chunks.slice();
        return .{
            .node = slice.items(.node)[slice.len - 1],
            .x = self.bot_x,
            .y = slice.items(.end)[slice.len - 1] - 1,
        };
    }

    /// Convert to an Untracked highlight.
    pub fn untracked(self: Flattened) Untracked {
        // Note: we don't use startPin/endPin here because it is slightly
        // faster to reuse the slices.
        const slice = self.chunks.slice();
        const nodes = slice.items(.node);
        const starts = slice.items(.start);
        const ends = slice.items(.end);
        return .{
            .start = .{
                .node = nodes[0],
                .x = self.top_x,
                .y = starts[0],
            },
            .end = .{
                .node = nodes[nodes.len - 1],
                .x = self.bot_x,
                .y = ends[ends.len - 1] - 1,
            },
        };
    }
};
