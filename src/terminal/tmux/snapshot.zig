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

    /// The session these windows belong to.
    session_id: usize,

    /// The windows, in the order tmux reported them (index order).
    windows: []Window,

    /// Native-window groups from the `@affinities` session option.
    affinities: []const u8,

    pub const Window = struct {
        id: usize,

        /// The window's index in the session; see `Viewer.Window.index`.
        index: usize,

        name: []const u8,

        /// True for the session's current window.
        active: bool,

        /// True while one pane is zoomed to fill the window.
        zoomed: bool,

        /// The window's active pane.
        active_pane: usize,

        width: usize,
        height: usize,

        /// The full layout, including panes hidden by a zoom.
        layout: Layout,

        /// What tmux shows while the window is zoomed: the zoomed pane
        /// alone, at the full window size. Null when not zoomed.
        visible_layout: ?Layout,
    };

    /// Deep copy the given windows. The result is owned by the caller and
    /// must be released with `destroy`.
    pub fn create(
        alloc: Allocator,
        session_id: usize,
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
            .index = src.index,
            .name = try arena_alloc.dupe(u8, src.name),
            .active = src.active,
            .zoomed = src.zoomed,
            .active_pane = src.active_pane,
            .width = src.width,
            .height = src.height,
            .layout = try copyLayout(arena_alloc, src.layout),
            .visible_layout = if (src.visible_layout) |v|
                try copyLayout(arena_alloc, v)
            else
                null,
        };
        const affinities = if (windows.len > 0)
            try arena_alloc.dupe(u8, windows[0].affinities)
        else
            "";

        self.* = .{
            .alloc = alloc,
            .arena = arena.state,
            .session_id = session_id,
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

    pub fn findWindow(self: *Snapshot, window_id: usize) ?*Window {
        for (self.windows) |*window| {
            if (window.id == window_id) return window;
        }

        return null;
    }

    /// Record a rename tmux told us about after this snapshot was taken.
    /// Returns false if the window isn't in the snapshot.
    pub fn renameWindow(
        self: *Snapshot,
        window_id: usize,
        name: []const u8,
    ) Allocator.Error!bool {
        const window = self.findWindow(window_id) orelse return false;

        // The old name stays in the arena until the snapshot is replaced,
        // which happens on every layout change.
        var arena = self.arena.promote(self.alloc);
        defer self.arena = arena.state;
        window.name = try arena.allocator().dupe(u8, name);
        return true;
    }

    /// Record which window is the session's current one.
    pub fn setActiveWindow(self: *Snapshot, window_id: usize) void {
        for (self.windows) |*window| window.active = window.id == window_id;
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
    const visible: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0,2",
    );

    const windows: [1]Viewer.Window = .{.{
        .id = 3,
        .index = 1,
        .name = try arena.allocator().dupe(u8, "a b;c"),
        .active = true,
        .zoomed = true,
        .active_pane = 2,
        .width = 80,
        .height = 24,
        .affinities = try arena.allocator().dupe(u8, "3,4"),
        .layout_arena = .{},
        .layout = layout,
        .visible_layout = visible,
    }};

    const snapshot = try Snapshot.create(alloc, 7, &windows);
    defer snapshot.destroy();

    // Free the source so any shallow copy would be a use-after-free.
    arena.deinit();
    arena = .init(alloc);

    try testing.expectEqual(@as(usize, 7), snapshot.session_id);
    try testing.expectEqual(@as(usize, 1), snapshot.windows.len);
    const window = snapshot.windows[0];
    try testing.expectEqual(@as(usize, 3), window.id);
    try testing.expectEqual(@as(usize, 1), window.index);
    try testing.expectEqualStrings("a b;c", window.name);
    try testing.expect(window.active);
    try testing.expect(window.zoomed);
    try testing.expectEqual(@as(usize, 2), window.active_pane);
    try testing.expectEqualStrings("3,4", snapshot.affinities);
    const children = window.layout.content.horizontal;
    try testing.expectEqual(@as(usize, 2), children.len);
    try testing.expectEqual(@as(usize, 1), children[0].content.pane);
    try testing.expectEqual(@as(usize, 2), children[1].content.pane);
    try testing.expectEqual(@as(usize, 2), window.visible_layout.?.content.pane);
}

test "tmux snapshot records renames and the current window" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var arena: ArenaAllocator = .init(alloc);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,0");

    var windows: [2]Viewer.Window = undefined;
    for (&windows, 0..) |*window, i| window.* = .{
        .id = i,
        .index = i,
        .name = "shell",
        .active = i == 0,
        .zoomed = false,
        .active_pane = 0,
        .width = 80,
        .height = 24,
        .affinities = "",
        .layout_arena = .{},
        .layout = layout,
        .visible_layout = null,
    };

    const snapshot = try Snapshot.create(alloc, 0, &windows);
    defer snapshot.destroy();

    try testing.expect(try snapshot.renameWindow(1, "editor"));
    try testing.expect(!try snapshot.renameWindow(9, "nope"));
    try testing.expectEqualStrings("shell", snapshot.windows[0].name);
    try testing.expectEqualStrings("editor", snapshot.windows[1].name);

    snapshot.setActiveWindow(1);
    try testing.expect(!snapshot.windows[0].active);
    try testing.expect(snapshot.windows[1].active);
}
