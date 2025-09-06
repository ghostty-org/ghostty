const std = @import("std");
const assert = std.debug.assert;
const build_config = @import("../build_config.zig");
const ArenaAllocator = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

/// SplitTree represents a tree of view types that can be divided.
///
/// Concretely for Ghostty, it represents a tree of terminal views. In
/// its basic state, there are no splits and it is a single full-sized
/// terminal. However, it can be split arbitrarily many times among two
/// axes (horizontal and vertical) to create a tree of terminal views.
///
/// This is an immutable tree structure, meaning all operations on it
/// will return a new tree with the operation applied. This allows us to
/// store versions of the tree in a history for easy undo/redo. To facilitate
/// this, the stored View type must implement reference counting; this is left
/// as an implementation detail of the View type.
///
/// The View type will be stored as a pointer within the tree and must
/// implement a number of functions to work properly:
///
///   - `fn ref(*View, Allocator) Allocator.Error!*View` - Increase a
///     reference count of the view. The Allocator will be the allocator provided
///     to the tree operation. This is allowed to copy the value if it wants to;
///     the returned value is expected to be a new reference (but that may
///     just be a copy).
///
///   - `fn unref(*View, Allocator) void` - Decrease the reference count of a
///     view. The Allocator will be the allocator provided to the tree
///     operation.
///
///   - `fn eql(*const View, *const View) bool` - Check if two views are equal.
///
/// Optionally the following functions can also be implemented:
///
///   - `fn splitTreeLabel(*const View) []const u8` - Return a label that is used
///     for the debug view. If this isn't specified then the node handle
///     will be used.
///
/// Note: for both the ref and unref functions, the allocator is optional.
/// If the functions take less arguments, then the allocator will not be
/// passed.
pub fn SplitTree(comptime V: type) type {
    return struct {
        const Self = @This();

        /// The view that this tree contains.
        pub const View = V;

        /// The arena allocator used for all allocations in the tree.
        /// Since the tree is an immutable structure, this lets us
        /// cleanly free all memory when the tree is deinitialized.
        arena: ArenaAllocator,

        /// All the nodes in the tree. Node at index 0 is always the root.
        nodes: []const Node,

        /// The handle of the zoomed node. A "zoomed" node is one that is
        /// expected to be made the full size of the split tree. Various
        /// operations may unzoom (e.g. resize).
        zoomed: ?Node.Handle,

        /// An empty tree.
        pub const empty: Self = .{
            // Arena can be undefined because we have zero allocated nodes.
            // If our nodes are empty our deinit function doesn't touch the
            // arena.
            .arena = undefined,
            .nodes = &.{},
            .zoomed = null,
        };

        pub const Node = union(enum) {
            leaf: *View,
            split: Split,

            /// A handle into the nodes array. This lets us keep track of
            /// nodes with 16-bit handles rather than full pointer-width
            /// values.
            pub const Handle = enum(Backing) {
                root = 0,
                _,

                pub const Backing = u16;

                pub inline fn idx(self: Handle) usize {
                    return @intFromEnum(self);
                }

                /// Offset the handle by a given amount.
                pub fn offset(self: Handle, v: usize) Handle {
                    const self_usize: usize = @intCast(@intFromEnum(self));
                    const final = self_usize + v;
                    assert(final < std.math.maxInt(Backing));
                    return @enumFromInt(final);
                }
            };
        };

        pub const Split = struct {
            layout: Layout,
            ratio: f16,
            left: Node.Handle,
            right: Node.Handle,

            pub const Layout = enum { horizontal, vertical };
            pub const Direction = enum { left, right, down, up };
        };

        /// Initialize a new tree with a single view.
        pub fn init(gpa: Allocator, view: *View) Allocator.Error!Self {
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            const nodes = try alloc.alloc(Node, 1);
            nodes[0] = .{ .leaf = try viewRef(view, gpa) };
            errdefer viewUnref(view, gpa);

            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = null,
            };
        }

        pub fn deinit(self: *Self) void {
            // Important: only free memory if we have memory to free,
            // because we use an undefined arena for empty trees.
            if (self.nodes.len > 0) {
                // Unref all our views
                const gpa: Allocator = self.arena.child_allocator;
                for (self.nodes) |node| switch (node) {
                    .leaf => |view| viewUnref(view, gpa),
                    .split => {},
                };
                self.arena.deinit();
            }

            self.* = undefined;
        }

        /// Clone this tree, returning a new tree with the same nodes.
        pub fn clone(self: *const Self, gpa: Allocator) Allocator.Error!Self {
            // If we're empty then return an empty tree.
            if (self.isEmpty()) return .empty;

            // Create a new arena allocator for the clone.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // Allocate a new nodes array and copy the existing nodes into it.
            const nodes = try alloc.dupe(Node, self.nodes);

            // Increase the reference count of all the views in the nodes.
            try refNodes(gpa, nodes);

            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = self.zoomed,
            };
        }

        /// Returns true if this is an empty tree.
        pub fn isEmpty(self: *const Self) bool {
            // An empty tree has no nodes.
            return self.nodes.len == 0;
        }

        /// An iterator over all the views in the tree.
        pub fn iterator(
            self: *const Self,
        ) Iterator {
            return .{ .nodes = self.nodes };
        }

        pub const ViewEntry = struct {
            handle: Node.Handle,
            view: *View,
        };

        pub const Iterator = struct {
            i: Node.Handle = .root,
            nodes: []const Node,

            pub fn next(self: *Iterator) ?ViewEntry {
                // If we have no nodes, return null.
                if (@intFromEnum(self.i) >= self.nodes.len) return null;

                // Get the current node and increment the index.
                const handle = self.i;
                self.i = @enumFromInt(handle.idx() + 1);
                const node = self.nodes[handle.idx()];

                return switch (node) {
                    .leaf => |v| .{ .handle = handle, .view = v },
                    .split => self.next(),
                };
            }
        };

        /// Change the zoomed state to the given node. Assumes the handle
        /// is valid.
        pub fn zoom(self: *Self, handle: ?Node.Handle) void {
            if (handle) |v| {
                assert(@intFromEnum(v) >= 0);
                assert(@intFromEnum(v) < self.nodes.len);
            }
            self.zoomed = handle;
        }

        pub const Goto = union(enum) {
            /// Previous view, null if we're the first view.
            previous,

            /// Next view, null if we're the last view.
            next,

            /// Previous view, but wrapped around to the last view. May
            /// return the same view if this is the first view.
            previous_wrapped,

            /// Next view, but wrapped around to the first view. May return
            /// the same view if this is the last view.
            next_wrapped,

            /// A spatial direction. "Spatial" means that the direction is
            /// based on the nearest surface in the given direction visually
            /// as the surfaces are laid out on a 2D grid.
            spatial: Spatial.Direction,
        };

        /// Goto a view from a certain point in the split tree. Returns null
        /// if the direction results in no visitable view.
        ///
        /// Allocator is only used for temporary state for spatial navigation.
        pub fn goto(
            self: *const Self,
            alloc: Allocator,
            from: Node.Handle,
            to: Goto,
        ) Allocator.Error!?Node.Handle {
            return switch (to) {
                .previous => self.previous(from),
                .next => self.next(from),
                .previous_wrapped => self.previous(from) orelse self.deepest(.right, .root),
                .next_wrapped => self.next(from) orelse self.deepest(.left, .root),
                .spatial => |d| spatial: {
                    // Get our spatial representation.
                    var sp = try self.spatial(alloc);
                    defer sp.deinit(alloc);
                    break :spatial self.nearest(sp, from, d);
                },
            };
        }

        pub const Side = enum { left, right };

        /// Returns the deepest view in the tree in the given direction.
        /// This can be used to find the leftmost/rightmost surface within
        /// a given split structure.
        pub fn deepest(
            self: *const Self,
            side: Side,
            from: Node.Handle,
        ) Node.Handle {
            var current: Node.Handle = from;
            while (true) {
                switch (self.nodes[current.idx()]) {
                    .leaf => return current,
                    .split => |s| current = switch (side) {
                        .left => s.left,
                        .right => s.right,
                    },
                }
            }
        }

        /// Returns the previous view from the given node handle (which itself
        /// doesn't need to be a view). If there is no previous (this is the
        /// most previous view) then this will return null.
        ///
        /// "Previous" is defined as the previous node in an in-order
        /// traversal of the tree. This isn't a perfect definition and we
        /// may want to change this to something that better matches a
        /// spatial view of the tree later.
        fn previous(self: *const Self, from: Node.Handle) ?Node.Handle {
            return switch (self.previousBacktrack(from, .root)) {
                .result => |v| v,
                .backtrack, .deadend => null,
            };
        }

        /// Same as `previous`, but returns the next view instead.
        fn next(self: *const Self, from: Node.Handle) ?Node.Handle {
            return switch (self.nextBacktrack(from, .root)) {
                .result => |v| v,
                .backtrack, .deadend => null,
            };
        }

        // Design note: we use a recursive backtracking search because
        // split trees are never that deep, so we can abuse the stack as
        // a safe allocator (stack overflow unlikely unless the kernel is
        // tuned in some really weird way).
        const Backtrack = union(enum) {
            deadend,
            backtrack,
            result: Node.Handle,
        };

        fn previousBacktrack(
            self: *const Self,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            // If we reached the point that we're trying to find the previous
            // value of, then we need to backtrack from here.
            if (from == current) return .backtrack;

            return switch (self.nodes[current.idx()]) {
                // If we hit a leaf that isn't our target, then deadend.
                .leaf => .deadend,

                .split => |s| switch (self.previousBacktrack(from, s.left)) {
                    .result => |v| .{ .result = v },

                    // Backtrack from the left means we have to continue
                    // backtracking because we can't see what's before the left.
                    .backtrack => .backtrack,

                    // If we hit a deadend on the left then let's move right.
                    .deadend => switch (self.previousBacktrack(from, s.right)) {
                        .result => |v| .{ .result = v },

                        // Deadend means its not in this split at all since
                        // we already tracked the left.
                        .deadend => .deadend,

                        // Backtrack means that its in our left view because
                        // we can see the immediate previous and there MUST
                        // be leaves (we can't have split-only leaves).
                        .backtrack => .{ .result = self.deepest(.right, s.left) },
                    },
                },
            };
        }

        // See previousBacktrack for detailed comments. This is a mirror
        // of that.
        fn nextBacktrack(
            self: *const Self,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            if (from == current) return .backtrack;
            return switch (self.nodes[current.idx()]) {
                .leaf => .deadend,
                .split => |s| switch (self.nextBacktrack(from, s.right)) {
                    .result => |v| .{ .result = v },
                    .backtrack => .backtrack,
                    .deadend => switch (self.nextBacktrack(from, s.left)) {
                        .result => |v| .{ .result = v },
                        .deadend => .deadend,
                        .backtrack => .{ .result = self.deepest(.left, s.right) },
                    },
                },
            };
        }

        /// Returns the nearest leaf node (view) in the given direction.
        fn nearest(
            self: *const Self,
            sp: Spatial,
            from: Node.Handle,
            direction: Spatial.Direction,
        ) ?Node.Handle {
            const target = sp.slots[from.idx()];

            var result: ?struct {
                handle: Node.Handle,
                distance: f16,
            } = null;
            for (sp.slots, 0..) |slot, handle| {
                // Never match ourself
                if (handle == from.idx()) continue;

                // Only match leaves
                switch (self.nodes[handle]) {
                    .leaf => {},
                    .split => continue,
                }

                // Ensure it is in the proper direction
                if (!switch (direction) {
                    .left => slot.maxX() <= target.x,
                    .right => slot.x >= target.maxX(),
                    .up => slot.maxY() <= target.y,
                    .down => slot.y >= target.maxY(),
                }) continue;

                // Track our distance
                const dx = slot.x - target.x;
                const dy = slot.y - target.y;
                const distance = @sqrt(dx * dx + dy * dy);

                // If we have a nearest it must be closer.
                if (result) |n| {
                    if (distance >= n.distance) continue;
                }
                result = .{
                    .handle = @enumFromInt(handle),
                    .distance = distance,
                };
            }

            return if (result) |n| n.handle else null;
        }

        /// Resize the given node in place. The node MUST be a split (asserted).
        ///
        /// In general, this is an immutable data structure so this is
        /// heavily discouraged. However, this is provided for convenience
        /// and performance reasons where its very important for GUIs to
        /// update the ratio during a live resize than to redraw the entire
        /// widget tree.
        pub fn resizeInPlace(
            self: *Self,
            at: Node.Handle,
            ratio: f16,
        ) void {
            // Let's talk about this constCast. Our member are const but
            // we actually always own their memory. We don't want consumers
            // who directly access the nodes to be able to modify them
            // (without nasty stuff like this), but given this is internal
            // usage its perfectly fine to modify the node in-place.
            const s: *Split = @constCast(&self.nodes[at.idx()].split);
            s.ratio = ratio;
        }

        /// Insert another tree into this tree at the given node in the
        /// specified direction. The other tree will be inserted in the
        /// new direction. For example, if the direction is "right" then
        /// `insert` is inserted right of the existing node.
        ///
        /// The allocator will be used for the newly created tree.
        /// The previous trees will not be freed, but reference counts
        /// for the views will be increased accordingly for the new tree.
        pub fn split(
            self: *const Self,
            gpa: Allocator,
            at: Node.Handle,
            direction: Split.Direction,
            ratio: f16,
            insert: *const Self,
        ) Allocator.Error!Self {
            // The new arena for our new tree.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // We know we're going to need the sum total of the nodes
            // between the two trees plus one for the new split node.
            const nodes = try alloc.alloc(Node, self.nodes.len + insert.nodes.len + 1);
            if (nodes.len > std.math.maxInt(Node.Handle.Backing)) return error.OutOfMemory;

            // We can copy our nodes exactly as they are, since they're
            // mostly not changing (only `at` is changing).
            @memcpy(nodes[0..self.nodes.len], self.nodes);

            // We can copy the destination nodes as well directly next to
            // the source nodes. We just have to go through and offset
            // all the handles in the destination tree to account for
            // the shift.
            const nodes_inserted = nodes[self.nodes.len..][0..insert.nodes.len];
            @memcpy(nodes_inserted, insert.nodes);
            for (nodes_inserted) |*node| switch (node.*) {
                .leaf => {},
                .split => |*s| {
                    // We need to offset the handles in the split
                    s.left = s.left.offset(self.nodes.len);
                    s.right = s.right.offset(self.nodes.len);
                },
            };

            // Determine our split layout and if we're on the left
            const layout: Split.Layout, const left: bool = switch (direction) {
                .left => .{ .horizontal, true },
                .right => .{ .horizontal, false },
                .up => .{ .vertical, true },
                .down => .{ .vertical, false },
            };

            // Copy our previous value to the end of the nodes list and
            // create our new split node.
            nodes[nodes.len - 1] = nodes[at.idx()];
            nodes[at.idx()] = .{ .split = .{
                .layout = layout,
                .ratio = ratio,
                .left = @enumFromInt(if (left) self.nodes.len else nodes.len - 1),
                .right = @enumFromInt(if (left) nodes.len - 1 else self.nodes.len),
            } };

            // We need to increase the reference count of all the nodes.
            try refNodes(gpa, nodes);

            return .{
                .arena = arena,
                .nodes = nodes,
                // Splitting always resets zoom state.
                .zoomed = null,
            };
        }

        /// Remove a node from the tree.
        pub fn remove(
            self: *Self,
            gpa: Allocator,
            at: Node.Handle,
        ) Allocator.Error!Self {
            assert(at.idx() < self.nodes.len);

            // If we're removing node zero then we're clearing the tree.
            if (at == .root) return .empty;

            // The new arena for our new tree.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // Allocate our new nodes list with the number of nodes we'll
            // need after the removal.
            const nodes = try alloc.alloc(Node, self.countAfterRemoval(
                .root,
                at,
                0,
            ));

            var result: Self = .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = null,
            };

            // Traverse the tree and copy all our nodes into place.
            assert(self.removeNode(
                &result,
                0,
                .root,
                at,
            ) != 0);

            // Increase the reference count of all the nodes.
            try refNodes(gpa, nodes);

            return result;
        }

        fn removeNode(
            old: *Self,
            new: *Self,
            new_offset: usize,
            current: Node.Handle,
            target: Node.Handle,
        ) usize {
            assert(current != target);

            // If we have a zoomed node and this is it then we migrate it.
            if (old.zoomed) |v| {
                if (v == current) {
                    assert(new.zoomed == null);
                    new.zoomed = @enumFromInt(new_offset);
                }
            }

            // Let's talk about this constCast. Our member are const but
            // we actually always own their memory. We don't want consumers
            // who directly access the nodes to be able to modify them
            // (without nasty stuff like this), but given this is internal
            // usage its perfectly fine to modify the node in-place.
            const new_nodes: []Node = @constCast(new.nodes);

            switch (old.nodes[current.idx()]) {
                // Leaf is simple, just copy it over. We don't ref anything
                // yet because it'd make undo (errdefer) harder. We do that
                // all at once later.
                .leaf => |view| {
                    new_nodes[new_offset] = .{ .leaf = view };
                    return 1;
                },

                .split => |s| {
                    // If we're removing one of the split node sides then
                    // we remove the split node itself as well and only add
                    // the other (non-removed) side.
                    if (s.left == target) return old.removeNode(
                        new,
                        new_offset,
                        s.right,
                        target,
                    );
                    if (s.right == target) return old.removeNode(
                        new,
                        new_offset,
                        s.left,
                        target,
                    );

                    // Neither side is being directly removed, so we traverse.
                    const left = old.removeNode(
                        new,
                        new_offset + 1,
                        s.left,
                        target,
                    );
                    assert(left != 0);
                    const right = old.removeNode(
                        new,
                        new_offset + left + 1,
                        s.right,
                        target,
                    );
                    assert(right != 0);
                    new_nodes[new_offset] = .{ .split = .{
                        .layout = s.layout,
                        .ratio = s.ratio,
                        .left = @enumFromInt(new_offset + 1),
                        .right = @enumFromInt(new_offset + 1 + left),
                    } };

                    return left + right + 1;
                },
            }
        }

        /// Returns the number of nodes that would be needed to store
        /// the tree if the target node is removed.
        fn countAfterRemoval(
            self: *Self,
            current: Node.Handle,
            target: Node.Handle,
            acc: usize,
        ) usize {
            assert(current != target);

            return switch (self.nodes[current.idx()]) {
                // Leaf is simple, always takes one node.
                .leaf => acc + 1,

                // Split is slightly more complicated. If either side is the
                // target to remove, then we remove the split node as well
                // so our count is just the count of the other side.
                //
                // If neither side is the target, then we count both sides
                // and add one to account for the split node itself.
                .split => |s| if (s.left == target) self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) else if (s.right == target) self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) else self.countAfterRemoval(
                    s.left,
                    target,
                    acc,
                ) + self.countAfterRemoval(
                    s.right,
                    target,
                    acc,
                ) + 1,
            };
        }

        /// Reference all the nodes in the given slice, handling unref if
        /// any fail. This should be called LAST so you don't have to undo
        /// the refs at any further point after this.
        fn refNodes(gpa: Allocator, nodes: []Node) Allocator.Error!void {
            // We need to increase the reference count of all the nodes.
            // Careful accounting here so that we properly unref on error
            // only the nodes we referenced.
            var reffed: usize = 0;
            errdefer for (0..reffed) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| viewUnref(view, gpa),
                }
            };
            for (0..nodes.len) |i| {
                switch (nodes[i]) {
                    .split => {},
                    .leaf => |view| nodes[i] = .{ .leaf = try viewRef(view, gpa) },
                }
                reffed = i;
            }
            assert(reffed == nodes.len - 1);
        }

        /// Equalize this node and all its children, returning a new node with splits
        /// adjusted so that each split's ratio is based on the relative weight
        /// (number of leaves) of its children.
        pub fn equalize(
            self: *const Self,
            gpa: Allocator,
        ) Allocator.Error!Self {
            if (self.isEmpty()) return .empty;

            // Create a new arena allocator for the clone.
            var arena = ArenaAllocator.init(gpa);
            errdefer arena.deinit();
            const alloc = arena.allocator();

            // Allocate a new nodes array and copy the existing nodes into it.
            const nodes = try alloc.dupe(Node, self.nodes);

            // Go through and equalize our ratios based on weights.
            for (nodes) |*node| switch (node.*) {
                .leaf => {},
                .split => |*s| {
                    const weight_left = self.weight(s.left, s.layout, 0);
                    const weight_right = self.weight(s.right, s.layout, 0);
                    assert(weight_left > 0);
                    assert(weight_right > 0);
                    const total_f16: f16 = @floatFromInt(weight_left + weight_right);
                    const weight_left_f16: f16 = @floatFromInt(weight_left);
                    s.ratio = weight_left_f16 / total_f16;
                },
            };

            // Increase the reference count of all the views in the nodes.
            try refNodes(gpa, nodes);

            return .{
                .arena = arena,
                .nodes = nodes,
                .zoomed = self.zoomed,
            };
        }

        fn weight(
            self: *const Self,
            from: Node.Handle,
            layout: Split.Layout,
            acc: usize,
        ) usize {
            return switch (self.nodes[from.idx()]) {
                .leaf => acc + 1,
                .split => |s| if (s.layout == layout)
                    self.weight(s.left, layout, acc) +
                        self.weight(s.right, layout, acc)
                else
                    1,
            };
        }

        /// Resize the nearest split matching the layout by the given ratio.
        /// Positive is right and down.
        ///
        /// The ratio is a value between 0 and 1 representing the percentage
        /// to move the divider in the given direction. The percentage is
        /// of the entire grid size, not just the specific split size.
        /// We use the entire grid size because that's what Ghostty's
        /// `resize_split` keybind does, because it maps to a general human
        /// understanding of moving a split relative to the entire window
        /// (generally).
        ///
        /// For example, a ratio of 0.1 and a layout of `vertical` will find
        /// the nearest vertical split and move the divider down by 10% of
        /// the total grid height.
        ///
        /// If no matching split is found, this does nothing, but will always
        /// still return a cloned tree.
        pub fn resize(
            self: *const Self,
            gpa: Allocator,
            from: Node.Handle,
            layout: Split.Layout,
            ratio: f16,
        ) Allocator.Error!Self {
            assert(ratio >= 0 and ratio <= 1);
            assert(!std.math.isNan(ratio));
            assert(!std.math.isInf(ratio));

            // Fast path empty trees.
            if (self.isEmpty()) return .empty;

            // From this point forward worst case we return a clone.
            var result = try self.clone(gpa);
            errdefer result.deinit();

            // Find our nearest parent split node matching the layout.
            const parent_handle = switch (self.findParentSplit(
                layout,
                from,
                .root,
            )) {
                .deadend, .backtrack => return result,
                .result => |v| v,
            };

            // Get our spatial layout, because we need the dimensions of this
            // split with regards to the entire grid.
            var sp = try result.spatial(gpa);
            defer sp.deinit(gpa);

            // Get the ratio of the split relative to the full grid.
            const full_ratio = full_ratio: {
                // Our scale is the amount we need to multiply our individual
                // ratio by to get the full ratio. Its actually a ratio on its
                // own but I'm trying to avoid that word: its the ratio of
                // our spatial width/height to the total.
                const scale = switch (layout) {
                    .horizontal => sp.slots[parent_handle.idx()].width / sp.slots[0].width,
                    .vertical => sp.slots[parent_handle.idx()].height / sp.slots[0].height,
                };

                const current = result.nodes[parent_handle.idx()].split.ratio;
                break :full_ratio current * scale;
            };

            // Set the final new ratio, clamping it to [0, 1]
            result.resizeInPlace(
                parent_handle,
                @min(@max(full_ratio + ratio, 0), 1),
            );
            return result;
        }

        fn findParentSplit(
            self: *const Self,
            layout: Split.Layout,
            from: Node.Handle,
            current: Node.Handle,
        ) Backtrack {
            if (from == current) return .backtrack;
            return switch (self.nodes[current.idx()]) {
                .leaf => .deadend,
                .split => |s| switch (self.findParentSplit(
                    layout,
                    from,
                    s.left,
                )) {
                    .result => |v| .{ .result = v },
                    .backtrack => if (s.layout == layout)
                        .{ .result = current }
                    else
                        .backtrack,
                    .deadend => switch (self.findParentSplit(
                        layout,
                        from,
                        s.right,
                    )) {
                        .deadend => .deadend,
                        .result => |v| .{ .result = v },
                        .backtrack => if (s.layout == layout)
                            .{ .result = current }
                        else
                            .backtrack,
                    },
                },
            };
        }

        /// Spatial representation of the split tree. See spatial.
        pub const Spatial = struct {
            /// The slots of the spatial representation in the same order
            /// as the tree it was created from.
            slots: []const Slot,

            pub const empty: Spatial = .{ .slots = &.{} };

            pub const Direction = enum { left, right, down, up };

            const Slot = struct {
                x: f16,
                y: f16,
                width: f16,
                height: f16,

                fn maxX(self: *const Slot) f16 {
                    return self.x + self.width;
                }

                fn maxY(self: *const Slot) f16 {
                    return self.y + self.height;
                }
            };

            pub fn deinit(self: *Spatial, alloc: Allocator) void {
                alloc.free(self.slots);
                self.* = undefined;
            }
        };

        /// Spatial representation of the split tree. This can be used to
        /// better understand the layout of the tree in a 2D space.
        ///
        /// The bounds of the representation are always based on the total
        /// 2D space being 1x1. The x/y coordinates and width/height dimensions
        /// of each individual split and leaf are relative to this.
        /// This means that the spatial representation is a normalized
        /// representation of the actual space.
        ///
        /// The top-left corner of the tree is always (0, 0).
        ///
        /// We use a normalized form because we can calculate it without
        /// accessing to the actual rendered view sizes. These actual sizes
        /// may not be available at various times because GUI toolkits often
        /// only make them available once they're part of a widget tree and
        /// a SplitTree can represent views that aren't currently visible.
        pub fn spatial(
            self: *const Self,
            alloc: Allocator,
        ) Allocator.Error!Spatial {
            // No nodes, empty spatial representation.
            if (self.nodes.len == 0) return .empty;

            // Get our total dimensions.
            const dim = self.dimensions(.root);

            // Create our slots which will match our nodes exactly.
            const slots = try alloc.alloc(Spatial.Slot, self.nodes.len);
            errdefer alloc.free(slots);
            slots[0] = .{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(dim.width),
                .height = @floatFromInt(dim.height),
            };
            self.fillSpatialSlots(slots, .root);

            // Normalize the dimensions to 1x1 grid.
            for (slots) |*slot| {
                slot.x /= @floatFromInt(dim.width);
                slot.y /= @floatFromInt(dim.height);
                slot.width /= @floatFromInt(dim.width);
                slot.height /= @floatFromInt(dim.height);
            }

            return .{ .slots = slots };
        }

        fn fillSpatialSlots(
            self: *const Self,
            slots: []Spatial.Slot,
            current_: Node.Handle,
        ) void {
            const current = current_.idx();
            assert(slots[current].width >= 0 and slots[current].height >= 0);
            switch (self.nodes[current]) {
                // Leaf node, current slot is already filled by caller.
                .leaf => {},

                .split => |s| {
                    switch (s.layout) {
                        .horizontal => {
                            slots[s.left.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width * s.ratio,
                                .height = slots[current].height,
                            };
                            slots[s.right.idx()] = .{
                                .x = slots[current].x + slots[current].width * s.ratio,
                                .y = slots[current].y,
                                .width = slots[current].width * (1 - s.ratio),
                                .height = slots[current].height,
                            };
                        },

                        .vertical => {
                            slots[s.left.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y,
                                .width = slots[current].width,
                                .height = slots[current].height * s.ratio,
                            };
                            slots[s.right.idx()] = .{
                                .x = slots[current].x,
                                .y = slots[current].y + slots[current].height * s.ratio,
                                .width = slots[current].width,
                                .height = slots[current].height * (1 - s.ratio),
                            };
                        },
                    }

                    self.fillSpatialSlots(slots, s.left);
                    self.fillSpatialSlots(slots, s.right);
                },
            }
        }

        /// Get the dimensions of the tree starting from the given node.
        ///
        /// This creates relative dimensions (see Spatial) by assuming each
        /// leaf is exactly 1x1 unit in size.
        fn dimensions(self: *const Self, current: Node.Handle) struct {
            width: u16,
            height: u16,
        } {
            return switch (self.nodes[current.idx()]) {
                .leaf => .{ .width = 1, .height = 1 },
                .split => |s| split: {
                    const left = self.dimensions(s.left);
                    const right = self.dimensions(s.right);
                    break :split switch (s.layout) {
                        .horizontal => .{
                            .width = left.width + right.width,
                            .height = @max(left.height, right.height),
                        },

                        .vertical => .{
                            .width = @max(left.width, right.width),
                            .height = left.height + right.height,
                        },
                    };
                },
            };
        }

        /// Format the tree in a human-readable format. By default this will
        /// output a diagram followed by a textual representation. This can
        /// be controlled via the formatting string:
        ///
        ///   - `diagram` - Output a diagram of the split tree only.
        ///   - `text` - Output a textual representation of the split tree only.
        ///   - Empty - Output both a diagram and a textual representation.
        ///
        pub fn format(
            self: *const Self,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;

            if (self.nodes.len == 0) {
                try writer.writeAll("empty");
                return;
            }

            if (std.mem.eql(u8, fmt, "diagram")) {
                self.formatDiagram(writer) catch
                    try writer.writeAll("failed to draw split tree diagram");
            } else if (std.mem.eql(u8, fmt, "text")) {
                try self.formatText(writer, .root, 0);
            } else if (fmt.len == 0) {
                self.formatDiagram(writer) catch {};
                try self.formatText(writer, .root, 0);
            } else {
                return error.InvalidFormat;
            }
        }

        fn formatText(
            self: *const Self,
            writer: anytype,
            current: Node.Handle,
            depth: usize,
        ) !void {
            for (0..depth) |_| try writer.writeAll("  ");

            if (self.zoomed) |zoomed| if (zoomed == current) {
                try writer.writeAll("(zoomed) ");
            };

            switch (self.nodes[current.idx()]) {
                .leaf => |v| if (@hasDecl(View, "splitTreeLabel"))
                    try writer.print("leaf: {s}\n", .{v.splitTreeLabel()})
                else
                    try writer.print("leaf: {d}\n", .{current}),

                .split => |s| {
                    try writer.print("split (layout: {s}, ratio: {d:.2})\n", .{
                        @tagName(s.layout),
                        s.ratio,
                    });
                    try self.formatText(writer, s.left, depth + 1);
                    try self.formatText(writer, s.right, depth + 1);
                },
            }
        }

        fn formatDiagram(
            self: *const Self,
            writer: anytype,
        ) !void {
            // Use our arena's GPA to allocate some intermediate memory.
            // Requiring allocation for formatting is nasty but this is really
            // only used for debugging and testing and shouldn't hit OOM
            // scenarios.
            var arena: ArenaAllocator = .init(self.arena.child_allocator);
            defer arena.deinit();
            const alloc = arena.allocator();

            // Get our spatial representation.
            const sp = spatial: {
                const sp = try self.spatial(alloc);

                // Scale our spatial representation to have minimum width/height 1.
                var min_w: f16 = 1;
                var min_h: f16 = 1;
                for (sp.slots) |slot| {
                    if (slot.width > 0) min_w = @min(min_w, slot.width);
                    if (slot.height > 0) min_h = @min(min_h, slot.height);
                }

                const ratio_w: f16 = 1 / min_w;
                const ratio_h: f16 = 1 / min_h;
                const slots = try alloc.dupe(Spatial.Slot, sp.slots);
                for (slots) |*slot| {
                    slot.x *= ratio_w;
                    slot.y *= ratio_h;
                    slot.width *= ratio_w;
                    slot.height *= ratio_h;
                }

                break :spatial .{ .slots = slots };
            };

            // The width we need for the largest label.
            const max_label_width: usize = max_label_width: {
                if (!@hasDecl(View, "splitTreeLabel")) {
                    break :max_label_width std.math.log10(sp.slots.len) + 1;
                }

                var max: usize = 0;
                for (self.nodes) |node| switch (node) {
                    .split => {},
                    .leaf => |view| {
                        const label = view.splitTreeLabel();
                        max = @max(max, label.len);
                    },
                };

                break :max_label_width max;
            };

            // We need space for whitespace and ASCII art so add that.
            // We need to accommodate the leaf handle, whitespace, and
            // then the border.
            const cell_width = cell_width: {
                // Border + whitespace + label + whitespace + border.
                break :cell_width 2 + max_label_width + 2;
            };
            const cell_height = cell_height: {
                // Border + label + border. No whitespace needed on the
                // vertical axis.
                break :cell_height 1 + 1 + 1;
            };

            // Make a grid that can fit our entire ASCII diagram. We know
            // the width/height based on node 0.
            const grid = grid: {
                // Get our initial width/height. Each leaf is 1x1 in this.
                // We round up for this because partial widths/heights should
                // take up an extra cell.
                var width: usize = @intFromFloat(@ceil(sp.slots[0].width));
                var height: usize = @intFromFloat(@ceil(sp.slots[0].height));

                // We need space for whitespace and ASCII art so add that.
                // We need to accommodate the leaf handle, whitespace, and
                // then the border.
                width *= cell_width;
                height *= cell_height;

                const rows = try alloc.alloc([]u8, height);
                for (0..rows.len) |y| {
                    rows[y] = try alloc.alloc(u8, width + 1);
                    @memset(rows[y], ' ');
                    rows[y][width] = '\n';
                }
                break :grid rows;
            };

            // Draw each node
            for (sp.slots, 0..) |slot, handle| {
                // We only draw leaf nodes. Splits are only used for layout.
                const node = self.nodes[handle];
                switch (node) {
                    .leaf => {},
                    .split => continue,
                }

                // If our width/height is zero then we skip this.
                if (slot.width == 0 or slot.height == 0) continue;

                var x: usize = @intFromFloat(@floor(slot.x));
                var y: usize = @intFromFloat(@floor(slot.y));
                var width: usize = @intFromFloat(@max(@floor(slot.width), 1));
                var height: usize = @intFromFloat(@max(@floor(slot.height), 1));
                x *= cell_width;
                y *= cell_height;
                width *= cell_width;
                height *= cell_height;

                // Top border
                {
                    const top = grid[y][x..][0..width];
                    top[0] = '+';
                    for (1..width - 1) |i| top[i] = '-';
                    top[width - 1] = '+';
                }

                // Bottom border
                {
                    const bottom = grid[y + height - 1][x..][0..width];
                    bottom[0] = '+';
                    for (1..width - 1) |i| bottom[i] = '-';
                    bottom[width - 1] = '+';
                }

                // Left border
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x] = '|';
                for (y + 1..y + height - 1) |y_cur| grid[y_cur][x + width - 1] = '|';

                // Get our label text
                var buf: [10]u8 = undefined;
                const label: []const u8 = if (@hasDecl(View, "splitTreeLabel"))
                    node.leaf.splitTreeLabel()
                else
                    try std.fmt.bufPrint(&buf, "{d}", .{handle});

                // Draw the handle in the center
                const x_mid = width / 2 + x;
                const y_mid = height / 2 + y;
                const label_width = label.len;
                const label_start = x_mid - label_width / 2;
                const row = grid[y_mid][label_start..];
                _ = try std.fmt.bufPrint(row, "{s}", .{label});
            }

            // Output every row
            for (grid) |row| {
                // We currently have a bug in our height calculation that
                // results in trailing blank lines. Ignore those. We should
                // really fix our height calculation instead. If someone wants
                // to do that just remove this line and see the tests that fail
                // and go from there.
                if (row[0] == ' ') break;
                try writer.writeAll(row);
            }
        }

        fn viewRef(view: *View, gpa: Allocator) Allocator.Error!*View {
            const func = @typeInfo(@TypeOf(View.ref)).@"fn";
            return switch (func.params.len) {
                1 => view.ref(),
                2 => try view.ref(gpa),
                else => @compileError("invalid view ref function"),
            };
        }

        fn viewUnref(view: *View, gpa: Allocator) void {
            const func = @typeInfo(@TypeOf(View.unref)).@"fn";
            switch (func.params.len) {
                1 => view.unref(),
                2 => view.unref(gpa),
                else => @compileError("invalid view unref function"),
            }
        }

        /// Make this a valid gobject if we're in a GTK environment.
        pub const getGObjectType = switch (build_config.app_runtime) {
            .gtk => @import("gobject").ext.defineBoxed(
                Self,
                .{
                    // To get the type name we get the non-qualified type name
                    // of the view and append that to `GhosttySplitTree`.
                    .name = name: {
                        const type_name = @typeName(View);
                        const last = if (std.mem.lastIndexOfScalar(
                            u8,
                            type_name,
                            '.',
                        )) |idx|
                            type_name[idx + 1 ..]
                        else
                            type_name;
                        assert(last.len > 0);
                        break :name "GhosttySplitTree" ++ last;
                    },

                    .funcs = .{
                        .copy = &struct {
                            fn copy(self: *Self) callconv(.c) *Self {
                                const ptr = @import("glib").ext.create(Self);
                                ptr.* = if (self.nodes.len == 0)
                                    .empty
                                else
                                    self.clone(self.arena.child_allocator) catch @panic("oom");
                                return ptr;
                            }
                        }.copy,
                        .free = &struct {
                            fn free(self: *Self) callconv(.c) void {
                                self.deinit();
                                @import("glib").ext.destroy(self);
                            }
                        }.free,
                    },
                },
            ),

            .none => void,
        };
    };
}

const TestTree = SplitTree(TestView);

const TestView = struct {
    const Self = @This();

    label: []const u8,

    pub fn ref(self: *Self, alloc: Allocator) Allocator.Error!*Self {
        const ptr = try alloc.create(Self);
        ptr.* = self.*;
        return ptr;
    }

    pub fn unref(self: *Self, alloc: Allocator) void {
        alloc.destroy(self);
    }

    pub fn splitTreeLabel(self: *const Self) []const u8 {
        return self.label;
    }
};

test "SplitTree: empty tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: TestTree = .empty;
    defer t.deinit();

    const str = try std.fmt.allocPrint(alloc, "{}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\empty
    );
}

test "SplitTree: single node" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var v: TestTree.View = .{ .label = "A" };
    var t: TestTree = try .init(alloc, &v);
    defer t.deinit();

    const str = try std.fmt.allocPrint(alloc, "{diagram}", .{t});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\
    );
}

test "SplitTree: split horizontal" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer t3.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{t3});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  leaf: B
            \\
        );
    }

    // Split right at B
    var vC: TestTree.View = .{ .label = "C" };
    var tC: TestTree = try .init(alloc, &vC);
    defer tC.deinit();
    var it = t3.iterator();
    var t4 = try t3.split(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound,
        .right,
        0.5,
        &tC,
    );
    defer t4.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{t4});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+--------++---++---+
            \\|    A   || B || C |
            \\+--------++---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  split (layout: horizontal, ratio: 0.50)
            \\    leaf: B
            \\    leaf: C
            \\
        );
    }

    // Split right at C
    var vD: TestTree.View = .{ .label = "D" };
    var tD: TestTree = try .init(alloc, &vD);
    defer tD.deinit();
    it = t4.iterator();
    var t5 = try t4.split(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "C")) {
                break entry.handle;
            }
        } else return error.NotFound,
        .right,
        0.5,
        &tD,
    );
    defer t5.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{t5});
        defer alloc.free(str);
        try testing.expectEqualStrings(
            \\+------------------++--------++---++---+
            \\|         A        ||    B   || C || D |
            \\+------------------++--------++---++---+
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  split (layout: horizontal, ratio: 0.50)
            \\    leaf: B
            \\    split (layout: horizontal, ratio: 0.50)
            \\      leaf: C
            \\      leaf: D
            \\
        , str);
    }

    // Find "previous" from D back.
    {
        var current: u8 = 'D';
        while (current != 'A') : (current -= 1) {
            it = t5.iterator();
            const handle = t5.previous(
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, &.{current})) {
                        break entry.handle;
                    }
                } else return error.NotFound,
            ).?;

            const entry = t5.nodes[handle.idx()].leaf;
            try testing.expectEqualStrings(
                entry.label,
                &.{current - 1},
            );
        }

        it = t5.iterator();
        try testing.expect(t5.previous(
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, &.{current})) {
                    break entry.handle;
                }
            } else return error.NotFound,
        ) == null);
    }

    // Find "next" from A forward.
    {
        var current: u8 = 'A';
        while (current != 'D') : (current += 1) {
            it = t5.iterator();
            const handle = t5.next(
                while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, &.{current})) {
                        break entry.handle;
                    }
                } else return error.NotFound,
            ).?;

            const entry = t5.nodes[handle.idx()].leaf;
            try testing.expectEqualStrings(
                entry.label,
                &.{current + 1},
            );
        }

        it = t5.iterator();
        try testing.expect(t5.next(
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, &.{current})) {
                    break entry.handle;
                }
            } else return error.NotFound,
        ) == null);
    }
}

test "SplitTree: split vertical" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    var t3 = try t1.split(
        alloc,
        .root, // at root
        .down, // split down
        0.5,
        &t2, // insert t2
    );
    defer t3.deinit();

    const str = try std.fmt.allocPrint(alloc, "{diagram}", .{t3});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| A |
        \\+---+
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}

test "SplitTree: split horizontal with zero ratio" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var splitAB = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0,
        &t2, // insert t2
    );
    defer splitAB.deinit();
    const split = splitAB;

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| B |
            \\+---+
            \\
        );
    }
}

test "SplitTree: split vertical with zero ratio" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var splitAB = try t1.split(
        alloc,
        .root, // at root
        .down, // split right
        0,
        &t2, // insert t2
    );
    defer splitAB.deinit();
    const split = splitAB;

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| B |
            \\+---+
            \\
        );
    }
}

test "SplitTree: split horizontal with full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var splitAB = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        1,
        &t2, // insert t2
    );
    defer splitAB.deinit();
    const split = splitAB;

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\
        );
    }
}

test "SplitTree: split vertical with full width" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var splitAB = try t1.split(
        alloc,
        .root, // at root
        .down, // split right
        1,
        &t2, // insert t2
    );
    defer splitAB.deinit();
    const split = splitAB;

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\
        );
    }
}

test "SplitTree: remove leaf" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var t3 = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer t3.deinit();

    // Remove "A"
    var it = t3.iterator();
    var t4 = try t3.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer t4.deinit();

    const str = try std.fmt.allocPrint(alloc, "{diagram}", .{t4});
    defer alloc.free(str);
    try testing.expectEqualStrings(str,
        \\+---+
        \\| B |
        \\+---+
        \\
    );
}

test "SplitTree: split twice, remove intermediary" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();

    // A | B horizontal.
    var split1 = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer split1.deinit();

    // Insert C below that.
    var split2 = try split1.split(
        alloc,
        .root, // at root
        .down, // split down
        0.5,
        &t3, // insert t3
    );
    defer split2.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split2});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\+--------+
            \\|    C   |
            \\+--------+
            \\
        );
    }

    // Remove "B"
    var it = split2.iterator();
    var split3 = try split2.remove(
        alloc,
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound,
    );
    defer split3.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split3});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---+
            \\| A |
            \\+---+
            \\+---+
            \\| C |
            \\+---+
            \\
        );
    }

    // Remove every node from split2 (our most complex one), which should
    // never crash. We don't test the result is correct, this just verifies
    // we don't hit any assertion failures.
    for (0..split2.nodes.len) |i| {
        var t = try split2.remove(alloc, @enumFromInt(i));
        t.deinit();
    }
}

test "SplitTree: spatial goto" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();
    var v3: TestTree.View = .{ .label = "C" };
    var t3: TestTree = try .init(alloc, &v3);
    defer t3.deinit();
    var v4: TestTree.View = .{ .label = "D" };
    var t4: TestTree = try .init(alloc, &v4);
    defer t4.deinit();

    // A | B horizontal
    var splitAB = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer splitAB.deinit();

    // A | C vertical
    var splitAC = try splitAB.split(
        alloc,
        at: {
            var it = splitAB.iterator();
            break :at while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, "A")) {
                    break entry.handle;
                }
            } else return error.NotFound;
        },
        .down, // split down
        0.8,
        &t3, // insert t3
    );
    defer splitAC.deinit();

    // B | D vertical
    var splitBD = try splitAC.split(
        alloc,
        at: {
            var it = splitAB.iterator();
            break :at while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.view.label, "B")) {
                    break entry.handle;
                }
            } else return error.NotFound;
        },
        .down, // split down
        0.3,
        &t4, // insert t4
    );
    defer splitBD.deinit();
    const split = splitBD;

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\|   || B |
            \\|   |+---+
            \\|   |+---+
            \\| A ||   |
            \\|   ||   |
            \\|   ||   |
            \\|   || D |
            \\+---+|   |
            \\+---+|   |
            \\| C ||   |
            \\+---++---+
            \\
        );
    }

    // Spatial C => right
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "C")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .right },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings(view.label, "D");
    }

    // Spatial D => left
    {
        const target = (try split.goto(
            alloc,
            from: {
                var it = split.iterator();
                break :from while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "D")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .{ .spatial = .left },
        )).?;
        const view = split.nodes[target.idx()].leaf;
        try testing.expectEqualStrings("A", view.label);
    }

    // Equalize
    var equal = try split.equalize(alloc);
    defer equal.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{equal});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\+---++---+
            \\| C || D |
            \\+---++---+
            \\
        );
    }
}

test "SplitTree: resize" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var split = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer split.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+---++---+
            \\| A || B |
            \\+---++---+
            \\
        );
    }

    // Resize
    {
        var resized = try split.resize(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
            .horizontal, // resize right
            0.25,
        );
        defer resized.deinit();
        const str = try std.fmt.allocPrint(alloc, "{diagram}", .{resized});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\+-------------++---+
            \\|      A      || B |
            \\+-------------++---+
            \\
        );
    }
}

test "SplitTree: clone empty tree" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var t: TestTree = .empty;
    defer t.deinit();

    var t2 = try t.clone(alloc);
    defer t2.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{}", .{t2});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\empty
        );
    }
}

test "SplitTree: zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var split = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer split.deinit();
    split.zoom(at: {
        var it = split.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "B")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });

    {
        const str = try std.fmt.allocPrint(alloc, "{text}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  (zoomed) leaf: B
            \\
        );
    }

    // Clone preserves zoom
    var clone = try split.clone(alloc);
    defer clone.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{text}", .{clone});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  (zoomed) leaf: B
            \\
        );
    }
}

test "SplitTree: split resets zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // Zoom A
    t1.zoom(at: {
        var it = t1.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });

    // A | B horizontal
    var split = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer split.deinit();

    {
        const str = try std.fmt.allocPrint(alloc, "{text}", .{split});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\split (layout: horizontal, ratio: 0.50)
            \\  leaf: A
            \\  leaf: B
            \\
        );
    }
}

test "SplitTree: remove and zoom" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var v1: TestTree.View = .{ .label = "A" };
    var t1: TestTree = try .init(alloc, &v1);
    defer t1.deinit();
    var v2: TestTree.View = .{ .label = "B" };
    var t2: TestTree = try .init(alloc, &v2);
    defer t2.deinit();

    // A | B horizontal
    var split = try t1.split(
        alloc,
        .root, // at root
        .right, // split right
        0.5,
        &t2, // insert t2
    );
    defer split.deinit();
    split.zoom(at: {
        var it = split.iterator();
        break :at while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.view.label, "A")) {
                break entry.handle;
            }
        } else return error.NotFound;
    });

    // Remove A, should unzoom
    {
        var removed = try split.remove(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "A")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
        );
        defer removed.deinit();
        try testing.expect(removed.zoomed == null);

        const str = try std.fmt.allocPrint(alloc, "{text}", .{removed});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\leaf: B
            \\
        );
    }

    // Remove B, should keep zoom
    {
        var removed = try split.remove(
            alloc,
            at: {
                var it = split.iterator();
                break :at while (it.next()) |entry| {
                    if (std.mem.eql(u8, entry.view.label, "B")) {
                        break entry.handle;
                    }
                } else return error.NotFound;
            },
        );
        defer removed.deinit();

        const str = try std.fmt.allocPrint(alloc, "{text}", .{removed});
        defer alloc.free(str);
        try testing.expectEqualStrings(str,
            \\(zoomed) leaf: A
            \\
        );
    }
}
