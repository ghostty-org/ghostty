//! An owned copy of the tmux window state that can cross threads.
//!
//! The viewer keeps its window list (and the layout tree inside each
//! window) in memory owned by the IO thread and reuses that memory on
//! every update. The GUI thread needs the same information to build
//! native windows, tabs and splits, so we deep copy it into a snapshot
//! whose ownership is handed over with the message.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const Layout = @import("layout.zig").Layout;
const Viewer = @import("viewer.zig").Viewer;

pub const Snapshot = struct {
    /// The allocator that owns this snapshot, including the struct itself.
    alloc: Allocator,

    /// Arena holding `windows` and every layout tree within it.
    arena: ArenaAllocator.State,

    /// The windows, in the order tmux reported them.
    windows: []const Window,

    /// iTerm2-compatible native-window groups from tmux's @affinities.
    affinities: []const u8,

    pub const Window = struct {
        id: usize,
        width: usize,
        height: usize,
        layout: Layout,
    };

    /// Deep copy the given windows. The result is owned by the caller and
    /// must be released with `destroy`.
    pub fn create(
        alloc: Allocator,
        windows: []const Viewer.Window,
    ) Allocator.Error!*Snapshot {
        const self = try alloc.create(Snapshot);
        errdefer alloc.destroy(self);

        var arena: ArenaAllocator = .init(alloc);
        errdefer arena.deinit();
        const arena_alloc = arena.allocator();

        const copy = try arena_alloc.alloc(Window, windows.len);
        for (windows, copy) |src, *dst| dst.* = .{
            .id = src.id,
            .width = src.width,
            .height = src.height,
            .layout = try copyLayout(arena_alloc, src.layout),
        };
        const affinities = if (windows.len > 0)
            try arena_alloc.dupe(u8, windows[0].affinities)
        else
            "";

        self.* = .{
            .alloc = alloc,
            .arena = arena.state,
            .windows = copy,
            .affinities = affinities,
        };

        return self;
    }

    pub fn destroy(self: *Snapshot) void {
        const alloc = self.alloc;
        self.arena.promote(alloc).deinit();
        alloc.destroy(self);
    }

    fn copyLayout(alloc: Allocator, src: Layout) Allocator.Error!Layout {
        return .{
            .width = src.width,
            .height = src.height,
            .x = src.x,
            .y = src.y,
            .content = switch (src.content) {
                .pane => |id| .{ .pane = id },

                inline .horizontal,
                .vertical,
                => |children, tag| content: {
                    const copy = try alloc.alloc(Layout, children.len);
                    for (children, copy) |child, *dst| {
                        dst.* = try copyLayout(alloc, child);
                    }

                    break :content @unionInit(
                        Layout.Content,
                        @tagName(tag),
                        copy,
                    );
                },
            },
        };
    }
};

test "tmux snapshot copies the layout tree" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var arena: ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
    );

    const windows: [1]Viewer.Window = .{.{
        .id = 3,
        .width = 80,
        .height = 24,
        .affinities = "3,4",
        .layout_arena = .{},
        .layout = layout,
    }};

    const snapshot = try Snapshot.create(alloc, &windows);
    defer snapshot.destroy();

    // Free the source so any shallow copy would be a use-after-free.
    arena.deinit();
    arena = .init(alloc);

    try testing.expectEqual(@as(usize, 1), snapshot.windows.len);
    try testing.expectEqual(@as(usize, 3), snapshot.windows[0].id);
    try testing.expectEqualStrings("3,4", snapshot.affinities);
    const children = snapshot.windows[0].layout.content.horizontal;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(@as(usize, 1), children[0].content.pane);
    try testing.expectEqual(@as(usize, 2), children[1].content.pane);
}
