//! Conversion between tmux window layouts and native split trees.
//!
//! tmux lays a window out as an n-ary tree: a container holds any number
//! of panes or other containers side by side (`{}`) or stacked (`[]`), with
//! a one-cell divider between neighbors. The native split tree is binary
//! and sizes the two halves of every split with a ratio. This module
//! converts between the two. It knows nothing about surfaces or the tmux
//! session, so every number can be tested exactly.
//!
//! A container with children c_0..c_(k-1) becomes a right-leaning chain of
//! splits B_i = split(c_i, B_(i+1)), the last one holding c_(k-2) and
//! c_(k-1). The left half of every split is exactly one tmux child, so a
//! divider drag on a split maps back to resizing that one child.
//!
//! The dividers have no native counterpart, so each one is shared evenly
//! by its two neighbors: child c_i owns o_i = s_i + 1 cells, where s_i is
//! its size, except the first and last child which own s_i + 0.5. The
//! owned sizes add up to the container size, and split B_i gets the ratio
//! o_i / E_i with E_i = o_i + ... + o_(k-1).

const std = @import("std");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const terminal = @import("terminal/main.zig");

const Layout = terminal.tmux.Layout;

pub const Node = apprt.action.TmuxWindow.Node;
pub const Split = apprt.action.TmuxWindow.Split;

/// The binary split tree of one tmux window layout.
pub const Tree = struct {
    /// `nodes[0]` is the root and handles index this slice. Leaves carry
    /// the tmux pane id and a null surface for the caller to fill in.
    nodes: []Node,

    /// Handle of the zoomed pane's leaf, if that pane is in the layout.
    zoomed: ?u16,

    /// Handle of the focused pane's leaf, if that pane is in the layout.
    focused: ?u16,

    pub const InitError = Allocator.Error || error{LayoutTooLarge};

    /// Convert `layout`. `zoomed_pane` and `focused_pane` are tmux pane
    /// ids that are looked up to fill in `zoomed` and `focused`.
    ///
    /// Nodes are numbered in pre-order: a split comes before its left
    /// subtree, which comes before its right subtree. `resizeForRatio`
    /// relies on this numbering.
    ///
    /// Returns `LayoutTooLarge` if the tree has more nodes than 16-bit
    /// handles can address.
    pub fn init(
        alloc: Allocator,
        layout: Layout,
        zoomed_pane: ?usize,
        focused_pane: ?usize,
    ) InitError!Tree {
        // A binary tree with n leaves has 2n - 1 nodes.
        const panes = countPanes(&layout);
        if (panes > (std.math.maxInt(u16) + 1) / 2) return error.LayoutTooLarge;
        const nodes = try alloc.alloc(Node, 2 * panes - 1);
        errdefer alloc.free(nodes);

        var builder: Builder = .{
            .nodes = nodes,
            .zoomed_pane = zoomed_pane,
            .focused_pane = focused_pane,
        };
        _ = builder.node(&layout);
        assert(builder.len == nodes.len);

        return .{
            .nodes = nodes,
            .zoomed = builder.zoomed,
            .focused = builder.focused,
        };
    }

    pub fn deinit(self: *Tree, alloc: Allocator) void {
        alloc.free(self.nodes);
        self.* = undefined;
    }
};

const Builder = struct {
    nodes: []Node,
    len: u16 = 0,
    zoomed_pane: ?usize,
    focused_pane: ?usize,
    zoomed: ?u16 = null,
    focused: ?u16 = null,

    /// Add the subtree of `layout` and return the handle of its root,
    /// which is always the first node added.
    fn node(self: *Builder, layout: *const Layout) u16 {
        switch (layout.content) {
            .pane => |pane| {
                const handle = self.len;
                self.len += 1;
                self.nodes[handle] = .{ .leaf = .{ .pane = pane, .surface = null } };
                if (self.zoomed_pane) |v| if (v == pane) {
                    self.zoomed = handle;
                };
                if (self.focused_pane) |v| if (v == pane) {
                    self.focused = handle;
                };
                return handle;
            },
            .horizontal => |children| return self.container(.horizontal, children),
            .vertical => |children| return self.container(.vertical, children),
        }
    }

    /// Add the chain of splits for one container. This loops rather than
    /// recursing along the chain so that a container with very many
    /// children can't exhaust the stack.
    fn container(
        self: *Builder,
        layout: Split.Layout,
        children: []const Layout,
    ) u16 {
        const root = self.len;

        // E_i, starting with the whole container.
        var rest: f64 = 0;
        for (0..children.len) |i| rest += owned(layout, children, i);

        for (children[0 .. children.len - 1], 0..) |*child, i| {
            const own = owned(layout, children, i);
            const handle = self.len;
            self.len += 1;
            const left = self.node(child);

            // Pre-order: the rest of the chain starts right after the
            // left subtree.
            self.nodes[handle] = .{ .split = .{
                .layout = layout,
                .ratio = @floatCast(own / rest),
                .left = left,
                .right = self.len,
            } };
            rest -= own;
        }

        // A container with one child adds no split at all.
        _ = self.node(&children[children.len - 1]);
        return root;
    }
};

/// What tmux needs to move a native divider to where it was dragged:
/// `resize-pane -t %<pane> -x <cells>` for horizontal splits, `-y` for
/// vertical ones.
pub const Resize = struct {
    pane: usize,
    layout: Split.Layout,
    cells: usize,

    /// Whether the resize leaves `layout`, the layout it was made for, as
    /// it is. tmux reports no layout change then. The pane spans the
    /// whole child it resizes along `layout` (see `resizeTarget`), so the
    /// child's size is the pane's.
    pub fn unchanged(self: Resize, layout: Layout) bool {
        const pane = findPane(&layout, self.pane) orelse return false;
        return extent(self.layout, pane) == self.cells;
    }
};

/// Convert a new `ratio` of the split at `handle`, in the tree that
/// `Tree.init` built from `layout`, into a tmux resize.
///
/// The split's left half is one tmux child c_i, so the result sets the
/// size of c_i: s_i = round(ratio * E_i - d), where d is the share of the
/// dividers that c_i owns besides its cells (0.5 for the first child, 1
/// otherwise). The size is clamped so that every later sibling keeps at
/// least one cell. It may equal the current size.
///
/// `resize-pane` resizes the child of the pane's nearest ancestor that has
/// the requested orientation. So the pane named in the result is one
/// inside c_i that is not inside another container of the split's
/// orientation. If c_i has no such pane, the last split of a container
/// can still be moved from its other side: tmux sizes the last child by
/// giving or taking the difference from the child before it, so the
/// result then sets the size of the last child to what c_i leaves of the
/// two. Otherwise tmux can't move the divider with one resize and this
/// returns null. It also returns null if `handle` is not a split or
/// `ratio` is NaN.
pub fn resizeForRatio(layout: Layout, handle: u16, ratio: f64) ?Resize {
    if (std.math.isNan(ratio)) return null;

    var next: usize = 0;
    const found = findSplit(&layout, &next, handle) orelse return null;
    const children = found.children;
    const i = found.index;

    var rest: f64 = 0;
    for (i..children.len) |j| rest += owned(found.layout, children, j);
    const d: f64 = if (i == 0) 0.5 else 1;
    const size = @round(ratio * rest - d);

    // c_i can take all but one cell from each later sibling.
    var max: usize = extent(found.layout, &children[i]);
    for (children[i + 1 ..]) |*child| max += extent(found.layout, child) - 1;
    const cells: usize = if (!(size >= 1))
        1
    else if (size >= @as(f64, @floatFromInt(max)))
        max
    else
        @intFromFloat(size);

    if (resizeTarget(found.layout, &children[i])) |pane| return .{
        .pane = pane,
        .layout = found.layout,
        .cells = cells,
    };

    // With c_i the second to last child, `max` above is what the two
    // children have between them, less one, so the last one keeps at
    // least a cell too.
    if (i + 2 != children.len) return null;
    const last = &children[i + 1];
    return .{
        .pane = resizeTarget(found.layout, last) orelse return null,
        .layout = found.layout,
        .cells = extent(found.layout, &children[i]) + extent(found.layout, last) - cells,
    };
}

const Found = struct {
    layout: Split.Layout,
    children: []const Layout,
    index: usize,
};

/// Find the container and child index behind the split at `handle`,
/// numbering nodes in the same pre-order as `Builder`. `next` is the
/// handle of the first node of `layout`.
fn findSplit(layout: *const Layout, next: *usize, handle: u16) ?Found {
    const orientation: Split.Layout, const children = switch (layout.content) {
        .pane => {
            next.* += 1;
            return null;
        },
        .horizontal => |v| .{ .horizontal, v },
        .vertical => |v| .{ .vertical, v },
    };

    for (children[0 .. children.len - 1], 0..) |*child, i| {
        if (next.* == handle) return .{
            .layout = orientation,
            .children = children,
            .index = i,
        };
        next.* += 1;
        if (findSplit(child, next, handle)) |found| return found;
    }

    return findSplit(&children[children.len - 1], next, handle);
}

/// A pane in `child` that `resize-pane` can use to resize `child` along
/// `layout`. tmux resizes the child of the nearest ancestor with that
/// orientation, so the search doesn't enter containers of that
/// orientation: their panes would resize a cell inside them instead.
fn resizeTarget(layout: Split.Layout, child: *const Layout) ?usize {
    const children = switch (child.content) {
        .pane => |pane| return pane,
        .horizontal => |v| if (layout == .horizontal) return null else v,
        .vertical => |v| if (layout == .vertical) return null else v,
    };
    for (children) |*c| if (resizeTarget(layout, c)) |pane| return pane;
    return null;
}

/// The cells that child `i` owns: its size plus its share of the
/// dividers next to it. Only meaningful with at least two children.
fn owned(layout: Split.Layout, children: []const Layout, i: usize) f64 {
    const size: f64 = @floatFromInt(extent(layout, &children[i]));
    const edge = i == 0 or i == children.len - 1;
    return size + @as(f64, if (edge) 0.5 else 1);
}

/// The size of `node` along the orientation of its container.
fn extent(layout: Split.Layout, node: *const Layout) usize {
    return switch (layout) {
        .horizontal => node.width,
        .vertical => node.height,
    };
}

fn findPane(layout: *const Layout, pane: usize) ?*const Layout {
    const children = switch (layout.content) {
        .pane => |id| return if (id == pane) layout else null,
        .horizontal, .vertical => |v| v,
    };
    for (children) |*child| if (findPane(child, pane)) |v| return v;
    return null;
}

fn countPanes(layout: *const Layout) usize {
    const children = switch (layout.content) {
        .pane => return 1,
        .horizontal, .vertical => |v| v,
    };
    var total: usize = 0;
    for (children) |*child| total += countPanes(child);
    return total;
}

/// The terminal grid tmux gives one pane.
pub const PaneGrid = struct {
    pane: usize,
    columns: usize,
    rows: usize,
};

/// Append the grid of every pane in `layout` to `list`.
///
/// A pane's grid is its size in the layout, except while a pane is zoomed:
/// then `visible` is the zoomed pane alone at the size of the whole window
/// and that pane gets that size. The other panes keep their layout sizes,
/// which is what they come back at when the zoom ends.
pub fn appendPaneGrids(
    alloc: Allocator,
    list: *std.ArrayList(PaneGrid),
    layout: Layout,
    visible: ?Layout,
) Allocator.Error!void {
    const zoomed: ?usize = if (visible) |v| switch (v.content) {
        .pane => |pane| pane,
        .horizontal, .vertical => null,
    } else null;

    const children = switch (layout.content) {
        .pane => |pane| {
            const size = if (zoomed == pane) visible.? else layout;
            try list.append(alloc, .{
                .pane = pane,
                .columns = size.width,
                .rows = size.height,
            });
            return;
        },
        .horizontal, .vertical => |v| v,
    };
    for (children) |child| try appendPaneGrids(alloc, list, child, visible);
}

/// Where the tab of a tmux window goes in its native window.
pub const Placement = struct {
    /// A window whose native window should get the tab if it doesn't
    /// exist yet, or null for a new native window.
    beside: ?usize,

    /// The window whose tab this one follows, or null to go before the
    /// other tabs of the group.
    after: ?usize,
};

/// Whether the follower of `pane` has to be released before a layout is
/// mirrored, because its pane is gone or tmux moved it to another window
/// than the one whose tab holds the follower. `pane_window` maps panes to
/// their window in the new layout, `placed` to the window whose tab their
/// follower was placed in.
///
/// Such a follower is released, which forgets its pane without telling
/// tmux, before its tab drops it. Dropped while still registered, it would
/// kill the pane as it closes, which for a moved pane is a pane tmux still
/// shows somewhere else.
pub fn isMisplaced(pane_window: anytype, placed: anytype, pane: usize) bool {
    const window = pane_window.get(pane) orelse return true;
    return placed.get(pane) != window;
}

/// Place the tab of `window`. `order` holds every tmux window id in index
/// order and `group` the windows that share a native window with it, in
/// any order and including `window` itself. `ctx.hasTab(id)` tells whether
/// a window already has a tab.
///
/// Tabs are created and updated in index order, so by the time `window` is
/// placed every group member before it has a tab. A tab follows the group
/// member just before it in index order; the first one of a group goes
/// into the native window of any group member that already has a tab.
pub fn placement(
    order: []const usize,
    group: []const usize,
    window: usize,
    ctx: anytype,
) Placement {
    var after: ?usize = null;
    for (order) |id| {
        if (id == window) break;
        if (std.mem.indexOfScalar(usize, group, id) != null) after = id;
    }

    const beside: ?usize = after orelse for (group) |id| {
        if (id != window and ctx.hasTab(id)) break id;
    } else null;

    return .{ .beside = beside, .after = after };
}

/// Which tmux window is current and which pane is active, as seen from
/// both sides, so that a change made on one side is shown on the other
/// once and never echoed back.
///
/// A native selection is sent to tmux right away and remembered as
/// pending until tmux reports it. Reports that arrive in the meantime
/// are about earlier changes that the native side has already moved past,
/// so they are not shown.
///
/// tmux reports nothing when the window or pane it is asked to select is
/// already the current one, which happens whenever our idea of tmux's
/// selection is out of date. A request is therefore also settled by a
/// window list that shows it done, and once it is `pending_timeout_ms`
/// old it no longer holds back tmux's reports: by then tmux has carried
/// it out, so it counts as landed.
///
/// Times are milliseconds on any monotonic clock.
pub const Selection = struct {
    /// tmux's current window, as last reported.
    window: ?usize = null,

    /// A window we asked tmux to make current that it hasn't reported yet.
    pending_window: ?usize = null,
    pending_window_at: i64 = 0,

    /// A pane we asked tmux to make active that it hasn't reported yet,
    /// and the window it is in.
    pending_pane: ?usize = null,
    pending_pane_window: usize = 0,
    pending_pane_at: i64 = 0,

    pub const pending_timeout_ms = 2000;

    /// The current window once every request in flight has landed.
    pub fn current(self: *const Selection) ?usize {
        return self.pending_window orelse self.window;
    }

    /// tmux reports `window` as its current window. Returns true if the
    /// native side should show it.
    pub fn tmuxWindow(self: *Selection, window: usize, now: i64) bool {
        self.expire(now);
        if (self.pending_window) |pending| {
            if (pending != window) return false;
            self.pending_window = null;
            self.window = window;
            return false;
        }

        self.window = window;
        return true;
    }

    /// A window list shows `window` as tmux's current window. Returns true
    /// if that changed without tmux reporting it, so that the native side
    /// has to catch up.
    pub fn listedWindow(self: *Selection, window: usize, now: i64) bool {
        self.expire(now);
        if (self.pending_window) |pending| {
            // A list taken before our request landed is out of date, one
            // taken after settles it.
            if (pending == window) {
                self.pending_window = null;
                self.window = window;
            }
            return false;
        }

        const changed = if (self.window) |v| v != window else false;
        self.window = window;
        return changed;
    }

    /// The user selected the tab of `window`. Returns true if tmux has to
    /// be told.
    pub fn nativeWindow(self: *Selection, window: usize, now: i64) bool {
        self.expire(now);
        if (self.current() == window) return false;
        self.pending_window = window;
        self.pending_window_at = now;
        return true;
    }

    /// tmux reports `pane` as the active pane of `window`. Returns true if
    /// the native side should focus it. Only reports about the window of
    /// a pending pane are held back: every window has an active pane of
    /// its own.
    pub fn tmuxPane(self: *Selection, window: usize, pane: usize, now: i64) bool {
        self.expire(now);
        if (self.pending_pane) |pending| {
            if (self.pending_pane_window != window) return true;
            if (pending == pane) self.pending_pane = null;
            return false;
        }
        return true;
    }

    /// A window list shows `pane` as the active pane of `window`, which
    /// settles a request for it.
    pub fn listedPane(self: *Selection, window: usize, pane: usize, now: i64) void {
        self.expire(now);
        const pending = self.pending_pane orelse return;
        if (self.pending_pane_window == window and pending == pane) {
            self.pending_pane = null;
        }
    }

    /// The user focused `pane` of `window`, which tmux knows as the active
    /// pane of its window if `active` says so. Returns true if tmux has to
    /// be told.
    pub fn nativePane(
        self: *Selection,
        window: usize,
        pane: usize,
        active: bool,
        now: i64,
    ) bool {
        self.expire(now);
        if (active or self.pending_pane == pane) return false;
        self.pending_pane = pane;
        self.pending_pane_window = window;
        self.pending_pane_at = now;
        return true;
    }

    /// Drop requests for windows or panes that no longer exist: tmux
    /// will never report them.
    pub fn forget(self: *Selection, ctx: anytype) void {
        if (self.pending_window) |v| if (!ctx.hasWindow(v)) {
            self.pending_window = null;
        };
        if (self.pending_pane) |v| if (!ctx.hasPane(v)) {
            self.pending_pane = null;
        };
        if (self.window) |v| if (!ctx.hasWindow(v)) {
            self.window = null;
        };
    }

    /// Treat requests that tmux has had long enough to carry out as
    /// landed.
    fn expire(self: *Selection, now: i64) void {
        if (self.pending_window) |v| if (now -| self.pending_window_at >= pending_timeout_ms) {
            self.pending_window = null;
            self.window = v;
        };
        if (self.pending_pane != null and now -| self.pending_pane_at >= pending_timeout_ms) {
            self.pending_pane = null;
        }
    }
};

/// One `swap-window -s @<a> -t @<b>`, which swaps the indexes of two tmux
/// windows. The session's current index stays current, whichever window
/// is at it afterwards.
pub const Swap = struct {
    a: usize,
    b: usize,
};

/// Plan the swaps that reorder tmux windows into a desired order.
///
/// `current` holds window ids in tmux index order and `desired` the same
/// windows in the order they should end up in. Windows that are only in
/// one of the two lists are ignored and keep their indexes, so a list that
/// is briefly out of date doesn't reorder anything else. Window ids are
/// expected to be unique.
///
/// This is a selection sort: each swap puts one window into its final
/// place, so n windows need at most n - 1 swaps. The swaps must be sent
/// in order. The caller owns the returned slice.
pub fn planSwaps(
    alloc: Allocator,
    current: []const usize,
    desired: []const usize,
) Allocator.Error![]Swap {
    var swaps: std.ArrayList(Swap) = .empty;
    errdefer swaps.deinit(alloc);

    const work = try alloc.dupe(usize, current);
    defer alloc.free(work);

    // Positions before `pos` that hold a window of `desired` are final.
    var pos: usize = 0;
    for (desired, 0..) |want, i| {
        if (std.mem.indexOfScalar(usize, current, want) == null) continue;
        if (std.mem.indexOfScalar(usize, desired[0..i], want) != null) continue;

        // Skip the windows that keep their index.
        while (std.mem.indexOfScalar(usize, desired, work[pos]) == null) pos += 1;

        // `want` is in both lists and not placed yet, so it is in an
        // unplaced position at or after `pos`.
        if (work[pos] != want) {
            const from = pos + 1 + std.mem.indexOfScalar(usize, work[pos + 1 ..], want).?;
            try swaps.append(alloc, .{ .a = work[pos], .b = want });
            std.mem.swap(usize, &work[pos], &work[from]);
        }
        pos += 1;
    }

    return try swaps.toOwnedSlice(alloc);
}

const testing = std.testing;

fn expectRatio(expected: f64, node: Node) !void {
    try testing.expectEqual(@as(f16, @floatCast(expected)), node.split.ratio);
}

fn expectLeaf(pane: usize, node: Node) !void {
    try testing.expectEqual(pane, node.leaf.pane);
    try testing.expect(node.leaf.surface == null);
}

fn expectSplit(
    layout: Split.Layout,
    left: u16,
    right: u16,
    node: Node,
) !void {
    try testing.expectEqual(layout, node.split.layout);
    try testing.expectEqual(left, node.split.left);
    try testing.expectEqual(right, node.split.right);
}

test "tmux mirror: followers of moved and gone panes are misplaced" {
    const Map = std.AutoHashMapUnmanaged(usize, usize);
    const alloc = testing.allocator;

    // Where tmux has each pane now.
    var pane_window: Map = .empty;
    defer pane_window.deinit(alloc);
    try pane_window.put(alloc, 1, 10);
    try pane_window.put(alloc, 2, 20);
    try pane_window.put(alloc, 4, 10);

    // Where their followers were placed.
    var placed: Map = .empty;
    defer placed.deinit(alloc);
    try placed.put(alloc, 1, 10);
    try placed.put(alloc, 2, 10);
    try placed.put(alloc, 3, 10);

    // Still in the window of its tab: kept, so reused by the new tree.
    try testing.expect(!isMisplaced(pane_window, placed, 1));

    // Moved to another window (break-pane, join-pane, move-pane): the
    // pane lives on there, so the follower here must not kill it.
    try testing.expect(isMisplaced(pane_window, placed, 2));

    // Killed in tmux: nothing left to kill.
    try testing.expect(isMisplaced(pane_window, placed, 3));

    // Never placed, for example a follower whose tab hasn't been
    // mirrored yet: it belongs to no tab that could keep it.
    try testing.expect(isMisplaced(pane_window, placed, 4));
}

test "tmux mirror: single pane" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,7");

    var tree: Tree = try .init(testing.allocator, layout, 7, 7);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(1, tree.nodes.len);
    try expectLeaf(7, tree.nodes[0]);
    try testing.expectEqual(0, tree.zoomed.?);
    try testing.expectEqual(0, tree.focused.?);
}

test "tmux mirror: two panes side by side" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
    );

    var tree: Tree = try .init(testing.allocator, layout, null, 2);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(3, tree.nodes.len);
    try expectSplit(.horizontal, 1, 2, tree.nodes[0]);
    try expectRatio(40.5 / 80.0, tree.nodes[0]);
    try testing.expectApproxEqAbs(0.50625, @as(f64, tree.nodes[0].split.ratio), 1e-3);
    try expectLeaf(1, tree.nodes[1]);
    try expectLeaf(2, tree.nodes[2]);
    try testing.expect(tree.zoomed == null);
    try testing.expectEqual(2, tree.focused.?);
}

test "tmux mirror: three panes become a right-leaning chain" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}",
    );

    var tree: Tree = try .init(testing.allocator, layout, null, null);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(5, tree.nodes.len);
    try expectSplit(.horizontal, 1, 2, tree.nodes[0]);
    try expectRatio(26.5 / 80.0, tree.nodes[0]);
    try expectLeaf(1, tree.nodes[1]);
    try expectSplit(.horizontal, 3, 4, tree.nodes[2]);
    try expectRatio(27.0 / 53.5, tree.nodes[2]);
    try expectLeaf(2, tree.nodes[3]);
    try expectLeaf(3, tree.nodes[4]);
}

test "tmux mirror: nested container" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}",
    );

    var tree: Tree = try .init(testing.allocator, layout, 3, 3);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(5, tree.nodes.len);
    try expectSplit(.horizontal, 1, 2, tree.nodes[0]);
    try expectRatio(40.5 / 80.0, tree.nodes[0]);
    try expectLeaf(1, tree.nodes[1]);
    try expectSplit(.vertical, 3, 4, tree.nodes[2]);
    try expectRatio(12.5 / 24.0, tree.nodes[2]);
    try expectLeaf(2, tree.nodes[3]);
    try expectLeaf(3, tree.nodes[4]);
    try testing.expectEqual(4, tree.zoomed.?);
    try testing.expectEqual(4, tree.focused.?);
}

test "tmux mirror: tiled 2x2" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0[80x12,0,0{40x12,0,0,1,39x12,41,0,2},80x11,0,13{40x11,0,13,3,39x11,41,13,4}]",
    );

    var tree: Tree = try .init(testing.allocator, layout, null, null);
    defer tree.deinit(testing.allocator);
    try testing.expectEqual(7, tree.nodes.len);
    try expectSplit(.vertical, 1, 4, tree.nodes[0]);
    try expectRatio(12.5 / 24.0, tree.nodes[0]);
    try expectSplit(.horizontal, 2, 3, tree.nodes[1]);
    try expectRatio(40.5 / 80.0, tree.nodes[1]);
    try expectLeaf(1, tree.nodes[2]);
    try expectLeaf(2, tree.nodes[3]);
    try expectSplit(.horizontal, 5, 6, tree.nodes[4]);
    try expectRatio(40.5 / 80.0, tree.nodes[4]);
    try expectLeaf(3, tree.nodes[5]);
    try expectLeaf(4, tree.nodes[6]);
}

test "tmux mirror: missing zoomed and focused panes" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
    );

    var tree: Tree = try .init(testing.allocator, layout, 9, 9);
    defer tree.deinit(testing.allocator);
    try testing.expect(tree.zoomed == null);
    try testing.expect(tree.focused == null);
}

test "tmux mirror: tree is accepted by the native split tree" {
    const SplitTree = @import("datastruct/split_tree.zig").SplitTree;
    const View = struct {
        const Self = @This();
        pane: usize,

        pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
            const ptr = try alloc.create(Self);
            ptr.* = self.*;
            return ptr;
        }

        pub fn unref(self: *Self, alloc: Allocator) void {
            alloc.destroy(self);
        }
    };
    const NativeTree = SplitTree(View);

    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const layout: Layout = try .parse(
        alloc,
        "80x24,0,0{40x24,0,0[40x12,0,0{20x12,0,0,1,19x12,21,0,2},40x11,0,13{20x11,0,13,3,19x11,21,13,4}],39x24,41,0,5}",
    );

    const tree: Tree = try .init(alloc, layout, 4, 5);
    const nodes = try alloc.alloc(NativeTree.Node, tree.nodes.len);
    for (tree.nodes, nodes) |node, *native| native.* = switch (node) {
        .leaf => |leaf| leaf: {
            const view = try alloc.create(View);
            view.* = .{ .pane = leaf.pane };
            break :leaf .{ .leaf = view };
        },
        .split => |s| .{ .split = .{
            .layout = switch (s.layout) {
                .horizontal => .horizontal,
                .vertical => .vertical,
            },
            .ratio = s.ratio,
            .left = @fromBackingInt(s.left),
            .right = @fromBackingInt(s.right),
        } },
    };

    var native: NativeTree = try .fromNodes(
        testing.allocator,
        nodes,
        @fromBackingInt(tree.zoomed.?),
    );
    defer native.deinit();

    var panes: [5]usize = undefined;
    var len: usize = 0;
    var it = native.iterator();
    while (it.next()) |entry| : (len += 1) panes[len] = entry.view.pane;
    try testing.expectEqualSlices(usize, &.{ 1, 2, 3, 4, 5 }, panes[0..len]);
}

test "tmux mirror: resize from a dragged ratio" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
    );

    // round(0.75 * 80 - 0.5) = round(59.5) = 60
    try testing.expectEqual(
        Resize{ .pane = 1, .layout = .horizontal, .cells = 60 },
        resizeForRatio(layout, 0, 0.75).?,
    );
    try testing.expect(!resizeForRatio(layout, 0, 0.75).?.unchanged(layout));

    // A drag that ends a fraction of a cell from where it started.
    try testing.expect(resizeForRatio(layout, 0, 40.6 / 80.0).?.unchanged(layout));

    // Pane 2 keeps at least one cell: 40 + (39 - 1) = 78.
    try testing.expectEqual(78, resizeForRatio(layout, 0, 0.999).?.cells);
    try testing.expectEqual(78, resizeForRatio(layout, 0, 1.5).?.cells);

    // Pane 1 keeps at least one cell.
    try testing.expectEqual(1, resizeForRatio(layout, 0, 0.001).?.cells);
    try testing.expectEqual(1, resizeForRatio(layout, 0, -1).?.cells);

    // Leaves, out of range handles and NaN have no resize.
    try testing.expect(resizeForRatio(layout, 1, 0.5) == null);
    try testing.expect(resizeForRatio(layout, 3, 0.5) == null);
    try testing.expect(resizeForRatio(layout, 0, std.math.nan(f64)) == null);
}

test "tmux mirror: resize a middle child" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const layout: Layout = try .parse(
        arena.allocator(),
        "80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}",
    );

    // Split 2 holds pane 2 and pane 3 over E_1 = 53.5 cells.
    // round(0.6 * 53.5 - 1) = round(31.1) = 31
    try testing.expectEqual(
        Resize{ .pane = 2, .layout = .horizontal, .cells = 31 },
        resizeForRatio(layout, 2, 0.6).?,
    );

    // Pane 3 keeps at least one cell: 26 + (26 - 1) = 51.
    try testing.expectEqual(51, resizeForRatio(layout, 2, 0.999).?.cells);
}

test "tmux mirror: resize round trips the converted ratios" {
    const layouts = [_][]const u8{
        "80x24,0,0{40x24,0,0,1,39x24,41,0,2}",
        "80x24,0,0{26x24,0,0,1,26x24,27,0,2,26x24,54,0,3}",
        "80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}",
        "80x24,0,0[80x12,0,0{40x12,0,0,1,39x12,41,0,2},80x11,0,13{40x11,0,13,3,39x11,41,13,4}]",
        "211x50,0,0{105x50,0,0,1,105x50,106,0[105x8,106,0,2,105x20,106,9,3,105x20,106,30{50x20,106,30,4,10x20,157,30,5,43x20,168,30,6}]}",
    };

    for (layouts) |str| {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const alloc = arena.allocator();
        const layout: Layout = try .parse(alloc, str);
        const tree: Tree = try .init(alloc, layout, null, null);

        for (tree.nodes, 0..) |node, h| {
            const s = switch (node) {
                .leaf => continue,
                .split => |s| s,
            };
            const resize = resizeForRatio(layout, @intCast(h), s.ratio).?;
            try testing.expectEqual(s.layout, resize.layout);

            // The left subtree is the resized child, so its first leaf
            // is the pane that resizeForRatio picks in these layouts.
            var first = s.left;
            while (tree.nodes[first] == .split) first = tree.nodes[first].split.left;
            try testing.expectEqual(tree.nodes[first].leaf.pane, resize.pane);

            // Converting the unchanged ratio back gives the current size.
            var next: usize = 0;
            const found = findSplit(&layout, &next, @intCast(h)).?;
            try testing.expectEqual(
                extent(found.layout, &found.children[found.index]),
                resize.cells,
            );
            try testing.expect(resize.unchanged(layout));
        }
    }
}

test "tmux mirror: resize target skips containers of the same orientation" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // {[{A,B},{C,D}],Y} with A..D = panes 1..4 and Y = pane 5:
    //   0 split h ([..] | Y)
    //   1   split v ({A,B} | {C,D})
    //   2     split h (A | B)
    //   3       A
    //   4       B
    //   5     split h (C | D)
    //   6       C
    //   7       D
    //   8   Y
    const grid: Layout = try .parse(
        alloc,
        "80x24,0,0{40x24,0,0[40x12,0,0{20x12,0,0,1,19x12,21,0,2},40x11,0,13{20x11,0,13,3,19x11,21,13,4}],39x24,41,0,5}",
    );

    // Every pane of the left half is inside a horizontal container, so
    // `resize-pane -x` on any of them resizes that container's child, not
    // the left half. Y is the last child though, so it is resized to what
    // the left half leaves: round(0.5 * 80 - 0.5) = 40 of 40 + 39 cells.
    try testing.expectEqual(
        Resize{ .pane = 5, .layout = .horizontal, .cells = 39 },
        resizeForRatio(grid, 0, 0.5).?,
    );
    try testing.expectEqual(
        Resize{ .pane = 5, .layout = .horizontal, .cells = 49 },
        resizeForRatio(grid, 0, 30.5 / 80.0).?,
    );

    // Y is 39 cells wide already: a left half of 40 cells leaves it so.
    try testing.expect(resizeForRatio(grid, 0, 0.5).?.unchanged(grid));
    try testing.expect(!resizeForRatio(grid, 0, 30.5 / 80.0).?.unchanged(grid));

    // Neither side has a pane of its own: no single resize moves it.
    const grids: Layout = try .parse(
        alloc,
        "80x24,0,0{40x24,0,0[40x12,0,0{20x12,0,0,1,19x12,21,0,2},40x11,0,13{20x11,0,13,3,19x11,21,13,4}],39x24,41,0[39x12,41,0{19x12,41,0,5,19x12,61,0,6},39x11,41,13{19x11,41,13,7,19x11,61,13,8}]}",
    );
    try testing.expect(resizeForRatio(grids, 0, 0.5) == null);

    // Only the last split of a container can use the last child.
    const three: Layout = try .parse(
        alloc,
        "80x24,0,0{26x24,0,0[26x12,0,0{13x12,0,0,1,12x12,14,0,2},26x11,0,13{13x11,0,13,3,12x11,14,13,4}],26x24,27,0,5,26x24,54,0,6}",
    );
    try testing.expect(resizeForRatio(three, 0, 0.3) == null);

    // The vertical split resizes {A,B}, through A.
    const vertical = resizeForRatio(grid, 1, 12.5 / 24.0).?;
    try testing.expectEqual(1, vertical.pane);
    try testing.expectEqual(.vertical, vertical.layout);
    try testing.expectEqual(12, vertical.cells);
    try testing.expect(vertical.unchanged(grid));

    // The inner horizontal splits resize A and C.
    try testing.expectEqual(
        Resize{ .pane = 1, .layout = .horizontal, .cells = 20 },
        resizeForRatio(grid, 2, 20.5 / 40.0).?,
    );
    try testing.expectEqual(
        Resize{ .pane = 3, .layout = .horizontal, .cells = 20 },
        resizeForRatio(grid, 5, 20.5 / 40.0).?,
    );

    // {[{A,B},C],Y}: C is directly in the vertical container, so it
    // resizes the left half.
    const mixed: Layout = try .parse(
        alloc,
        "80x24,0,0{40x24,0,0[40x12,0,0{20x12,0,0,1,19x12,21,0,2},40x11,0,13,3],39x24,41,0,5}",
    );
    try testing.expectEqual(
        Resize{ .pane = 3, .layout = .horizontal, .cells = 40 },
        resizeForRatio(mixed, 0, 40.5 / 80.0).?,
    );
}

fn expectSwaps(
    current: []const usize,
    desired: []const usize,
    expected: []const Swap,
    result: []const usize,
) !void {
    const swaps = try planSwaps(testing.allocator, current, desired);
    defer testing.allocator.free(swaps);
    try testing.expectEqualSlices(Swap, expected, swaps);

    // Replaying the swaps as tmux would gives the expected order.
    const order = try testing.allocator.dupe(usize, current);
    defer testing.allocator.free(order);
    for (swaps) |swap| {
        const a = std.mem.indexOfScalar(usize, order, swap.a).?;
        const b = std.mem.indexOfScalar(usize, order, swap.b).?;
        std.mem.swap(usize, &order[a], &order[b]);
    }
    try testing.expectEqualSlices(usize, result, order);
}

test "tmux mirror: swap planner" {
    // Already in order.
    try expectSwaps(&.{ 1, 2, 3 }, &.{ 1, 2, 3 }, &.{}, &.{ 1, 2, 3 });
    try expectSwaps(&.{}, &.{}, &.{}, &.{});

    // Move the last window to the front.
    try expectSwaps(
        &.{ 1, 2, 3 },
        &.{ 3, 1, 2 },
        &.{ .{ .a = 1, .b = 3 }, .{ .a = 2, .b = 1 } },
        &.{ 3, 1, 2 },
    );

    // Reverse four windows in two swaps.
    try expectSwaps(
        &.{ 1, 2, 3, 4 },
        &.{ 4, 3, 2, 1 },
        &.{ .{ .a = 1, .b = 4 }, .{ .a = 2, .b = 3 } },
        &.{ 4, 3, 2, 1 },
    );

    // Swap two neighbors.
    try expectSwaps(
        &.{ 5, 6, 7 },
        &.{ 5, 7, 6 },
        &.{.{ .a = 6, .b = 7 }},
        &.{ 5, 7, 6 },
    );
}

test "tmux mirror: swap planner ignores windows in only one list" {
    // Windows 2 and 4 are unknown to the native order and keep their
    // indexes; window 9 is unknown to tmux and is ignored, as is the
    // duplicate 3.
    try expectSwaps(
        &.{ 1, 2, 3, 4 },
        &.{ 3, 9, 3, 1 },
        &.{.{ .a = 1, .b = 3 }},
        &.{ 3, 2, 1, 4 },
    );

    try expectSwaps(&.{ 1, 2 }, &.{}, &.{}, &.{ 1, 2 });
    try expectSwaps(&.{}, &.{ 1, 2 }, &.{}, &.{});
}

test "tmux mirror: swap planner needs at most n - 1 swaps" {
    // Every permutation of four windows.
    var perm = [_]usize{ 1, 2, 3, 4 };
    const current = [_]usize{ 1, 2, 3, 4 };
    var count: usize = 0;
    while (true) {
        const swaps = try planSwaps(testing.allocator, &current, &perm);
        defer testing.allocator.free(swaps);
        try testing.expect(swaps.len <= current.len - 1);
        try expectSwaps(&current, &perm, swaps, &perm);
        count += 1;

        // Next permutation in lexicographic order.
        var i: usize = perm.len - 1;
        while (i > 0 and perm[i - 1] >= perm[i]) i -= 1;
        if (i == 0) break;
        var j: usize = perm.len - 1;
        while (perm[j] <= perm[i - 1]) j -= 1;
        std.mem.swap(usize, &perm[i - 1], &perm[j]);
        std.mem.reverse(usize, perm[i..]);
    }
    try testing.expectEqual(24, count);
}

test "tmux mirror: pane grids" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const layout: Layout = try .parse(
        alloc,
        "80x24,0,0{40x24,0,0,1,39x24,41,0[39x12,41,0,2,39x11,41,13,3]}",
    );

    var list: std.ArrayList(PaneGrid) = .empty;
    try appendPaneGrids(alloc, &list, layout, null);
    try testing.expectEqualSlices(PaneGrid, &.{
        .{ .pane = 1, .columns = 40, .rows = 24 },
        .{ .pane = 2, .columns = 39, .rows = 12 },
        .{ .pane = 3, .columns = 39, .rows = 11 },
    }, list.items);

    // Zoomed: the zoomed pane fills the window, the others keep the size
    // they come back at.
    const visible: Layout = try .parse(alloc, "80x24,0,0,2");
    list.clearRetainingCapacity();
    try appendPaneGrids(alloc, &list, layout, visible);
    try testing.expectEqualSlices(PaneGrid, &.{
        .{ .pane = 1, .columns = 40, .rows = 24 },
        .{ .pane = 2, .columns = 80, .rows = 24 },
        .{ .pane = 3, .columns = 39, .rows = 11 },
    }, list.items);
}

const TestTabs = struct {
    tabs: []const usize,

    pub fn hasTab(self: TestTabs, id: usize) bool {
        return std.mem.indexOfScalar(usize, self.tabs, id) != null;
    }
};

test "tmux mirror: tab placement" {
    const order = [_]usize{ 4, 1, 7, 2, 9 };

    // First of its group with no tabs yet: a new native window.
    try testing.expectEqual(
        Placement{ .beside = null, .after = null },
        placement(&order, &.{ 1, 2 }, 1, TestTabs{ .tabs = &.{} }),
    );

    // Later group members follow the one before them in index order,
    // whatever order the group lists them in.
    try testing.expectEqual(
        Placement{ .beside = 1, .after = 1 },
        placement(&order, &.{ 2, 1 }, 2, TestTabs{ .tabs = &.{} }),
    );
    try testing.expectEqual(
        Placement{ .beside = 7, .after = 7 },
        placement(&order, &.{ 4, 7, 9 }, 9, TestTabs{ .tabs = &.{4} }),
    );

    // A window that moved to the front of its group goes before the tabs
    // that already exist, in their native window.
    try testing.expectEqual(
        Placement{ .beside = 7, .after = null },
        placement(&order, &.{ 7, 9, 4 }, 4, TestTabs{ .tabs = &.{ 4, 7, 9 } }),
    );

    // A window alone in its group.
    try testing.expectEqual(
        Placement{ .beside = null, .after = null },
        placement(&order, &.{7}, 7, TestTabs{ .tabs = &.{7} }),
    );
}

test "tmux mirror: selection from tmux" {
    var s: Selection = .{};
    try testing.expect(s.tmuxWindow(1, 0));
    try testing.expectEqual(1, s.current().?);
    try testing.expect(s.tmuxWindow(2, 0));
    try testing.expect(s.tmuxPane(2, 5, 0));
    try testing.expectEqual(2, s.current().?);
}

test "tmux mirror: native selection is not echoed back" {
    var s: Selection = .{ .window = 1 };

    // Selecting the current window again needs nothing.
    try testing.expect(!s.nativeWindow(1, 0));

    // Two selections in a row: tmux is told about both, the report of the
    // first is stale by the time it arrives and neither is shown.
    try testing.expect(s.nativeWindow(2, 0));
    try testing.expect(!s.nativeWindow(2, 0));
    try testing.expect(s.nativeWindow(3, 0));
    try testing.expectEqual(3, s.current().?);
    try testing.expect(!s.tmuxWindow(2, 10));
    try testing.expectEqual(3, s.current().?);
    try testing.expect(!s.tmuxWindow(3, 20));
    try testing.expect(s.pending_window == null);
    try testing.expectEqual(3, s.window.?);

    // Once settled, tmux's own changes are shown again.
    try testing.expect(s.tmuxWindow(1, 30));
}

test "tmux mirror: native focus is not echoed back" {
    var s: Selection = .{};

    // The pane tmux already has active needs nothing.
    try testing.expect(!s.nativePane(1, 4, true, 0));

    try testing.expect(s.nativePane(1, 5, false, 0));
    try testing.expect(!s.nativePane(1, 5, false, 0));

    // A stale report doesn't move focus back, ours settles it.
    try testing.expect(!s.tmuxPane(1, 4, 10));
    try testing.expect(!s.tmuxPane(1, 5, 20));
    try testing.expect(s.pending_pane == null);
    try testing.expect(s.tmuxPane(1, 4, 30));
}

test "tmux mirror: a pending pane only holds back its own window" {
    var s: Selection = .{};
    try testing.expect(s.nativePane(1, 5, false, 0));

    // Another window's active pane changed on the tmux side.
    try testing.expect(s.tmuxPane(2, 8, 10));
    try testing.expectEqual(5, s.pending_pane.?);

    // The window of the pending pane is still held back.
    try testing.expect(!s.tmuxPane(1, 4, 20));
    try testing.expectEqual(5, s.pending_pane.?);
}

test "tmux mirror: a window list settles a request tmux never reports" {
    // tmux already had window 2 current, so selecting it reports nothing.
    var s: Selection = .{ .window = 1 };
    try testing.expect(s.nativeWindow(2, 0));

    // A list from before the request shows something else and is out of
    // date; one that shows the window settles it.
    try testing.expect(!s.listedWindow(1, 10));
    try testing.expectEqual(2, s.pending_window.?);
    try testing.expect(!s.listedWindow(2, 20));
    try testing.expect(s.pending_window == null);
    try testing.expectEqual(2, s.window.?);

    // tmux's own changes are shown again.
    try testing.expect(s.tmuxWindow(3, 30));

    // A list that shows another current window than the last report means
    // tmux changed it silently.
    try testing.expect(!s.listedWindow(3, 40));
    try testing.expect(s.listedWindow(4, 50));
    try testing.expectEqual(4, s.current().?);

    // The same for panes, per window.
    try testing.expect(s.nativePane(4, 7, false, 60));
    s.listedPane(5, 7, 70);
    try testing.expectEqual(7, s.pending_pane.?);
    s.listedPane(4, 6, 70);
    try testing.expectEqual(7, s.pending_pane.?);
    s.listedPane(4, 7, 80);
    try testing.expect(s.pending_pane == null);
    try testing.expect(s.tmuxPane(4, 6, 90));
}

test "tmux mirror: an unreported request expires" {
    const t = Selection.pending_timeout_ms;
    var s: Selection = .{ .window = 1 };
    try testing.expect(s.nativeWindow(2, 100));
    try testing.expect(s.nativePane(2, 5, false, 100));

    // Until it is old enough, other reports are held back.
    try testing.expect(!s.tmuxWindow(3, 100 + t - 1));
    try testing.expect(!s.tmuxPane(2, 6, 100 + t - 1));

    // Then it counts as landed and tmux's reports are shown again.
    try testing.expect(s.tmuxWindow(3, 100 + t));
    try testing.expect(s.pending_window == null);
    try testing.expectEqual(3, s.current().?);
    try testing.expect(s.tmuxPane(2, 6, 100 + t));
    try testing.expect(s.pending_pane == null);

    // An expired request is what tmux has current when nothing else was
    // reported, so selecting the window it replaced is sent again.
    s = .{ .window = 1 };
    try testing.expect(s.nativeWindow(2, 0));
    try testing.expect(s.nativeWindow(1, t));
    try testing.expectEqual(1, s.current().?);
}

test "tmux mirror: selection forgets what no longer exists" {
    const Live = struct {
        pub fn hasWindow(_: @This(), id: usize) bool {
            return id == 1;
        }
        pub fn hasPane(_: @This(), id: usize) bool {
            return id == 10;
        }
    };

    var s: Selection = .{ .window = 1, .pending_window = 2, .pending_pane = 11 };
    s.forget(Live{});
    try testing.expectEqual(1, s.window.?);
    try testing.expect(s.pending_window == null);
    try testing.expect(s.pending_pane == null);

    // tmux's reports are shown again.
    try testing.expect(s.tmuxWindow(1, 0));
    try testing.expect(s.tmuxPane(1, 10, 0));

    s = .{ .window = 3, .pending_pane = 10 };
    s.forget(Live{});
    try testing.expect(s.window == null);
    try testing.expectEqual(10, s.pending_pane.?);
}
