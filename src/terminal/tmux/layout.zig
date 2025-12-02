const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

/// A tmux layout.
///
/// This is a tree structure so by definition it pretty much needs to be
/// allocated. We leave allocation up to the user of this struct, but
/// a general recommendation is to use an arena allocator for simplicity
/// in freeing the entire layout at once.
pub const Layout = struct {
    /// Width, height of the node
    width: usize,
    height: usize,

    /// X and Y offset from the top-left corner of the window.
    x: usize,
    y: usize,

    /// The content of this node, either a pane (leaf) or more nodes
    /// (split) horizontally or vertically.
    content: Content,

    pub const Content = union(enum) {
        pane: usize,
        horizontal: []const Layout,
        vertical: []const Layout,
    };

    pub const ParseError = Allocator.Error || error{SyntaxError};

    /// Parse a layout string into a Layout structure. The given allocator
    /// will be used for all allocations within the layout. Note that
    /// individual nodes can't be freed so this allocator must be some
    /// kind of arena allocator.
    ///
    /// The layout string must be fully provided as a single string.
    /// Layouts are generally small so this should not be a problem.
    ///
    /// Tmux layout strings have the following format:
    ///
    /// - WxH,X,Y,ID Leaf pane: width×height, x-offset, y-offset, pane ID
    /// - WxH,X,Y{...} Horizontal split (left-right), children comma-separated
    /// - WxH,X,Y[...] Vertical split (top-bottom), children comma-separated
    pub fn parse(alloc: Allocator, str: []const u8) ParseError!Layout {
        var offset: usize = 0;
        const root = try parseNext(
            alloc,
            str,
            &offset,
        );
        if (offset != str.len) return error.SyntaxError;
        return root;
    }

    fn parseNext(
        alloc: Allocator,
        str: []const u8,
        offset: *usize,
    ) ParseError!Layout {
        // Find the first `x` to grab the width.
        const width: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            'x',
        )) |idx| width: {
            defer offset.* += idx + 1; // Consume `x`
            break :width std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find the height, up to a comma.
        const height: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| height: {
            defer offset.* += idx + 1; // Consume `,`
            break :height std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find X
        const x: usize = if (std.mem.indexOfScalar(
            u8,
            str[offset.*..],
            ',',
        )) |idx| x: {
            defer offset.* += idx + 1; // Consume `,`
            break :x std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Find Y, which can end in any of `,{,[`
        const y: usize = if (std.mem.indexOfAny(
            u8,
            str[offset.*..],
            ",{[",
        )) |idx| y: {
            defer offset.* += idx; // Don't consume the delimiter!
            break :y std.fmt.parseInt(
                usize,
                str[offset.* .. offset.* + idx],
                10,
            ) catch return error.SyntaxError;
        } else return error.SyntaxError;

        // Determine our child node.
        const content: Layout.Content = switch (str[offset.*]) {
            ',' => content: {
                // Consume the delimiter
                offset.* += 1;

                // Leaf pane. Read up to `,}]` because we may be in
                // a set of nodes. If none exist, end of string is fine.
                const idx = std.mem.indexOfAny(
                    u8,
                    str[offset.*..],
                    ",}]",
                ) orelse str.len - offset.*;

                defer offset.* += idx; // Consume the pane ID, not the delimiter
                const pane_id = std.fmt.parseInt(
                    usize,
                    str[offset.* .. offset.* + idx],
                    10,
                ) catch return error.SyntaxError;

                break :content .{ .pane = pane_id };
            },

            '{', '[' => |opening| content: {
                var nodes: std.ArrayList(Layout) = .empty;
                defer nodes.deinit(alloc);

                // Move beyond our opening
                offset.* += 1;

                while (true) {
                    try nodes.append(alloc, try parseNext(
                        alloc,
                        str,
                        offset,
                    ));

                    // We should not reach the end of string here because
                    // we expect a closing bracket.
                    if (offset.* >= str.len) return error.SyntaxError;

                    // If it is a comma, we expect another node.
                    if (str[offset.*] == ',') {
                        offset.* += 1; // Consume
                        continue;
                    }

                    // We expect a closing bracket now.
                    switch (opening) {
                        '{' => if (str[offset.*] != '}') return error.SyntaxError,
                        '[' => if (str[offset.*] != ']') return error.SyntaxError,
                        else => return error.SyntaxError,
                    }

                    // Successfully parsed all children.
                    offset.* += 1; // Consume closing bracket
                    break :content switch (opening) {
                        '{' => .{ .horizontal = try nodes.toOwnedSlice(alloc) },
                        '[' => .{ .vertical = try nodes.toOwnedSlice(alloc) },
                        else => unreachable,
                    };
                }
            },

            // indexOfAny above guarantees we have only the above
            else => unreachable,
        };

        return .{
            .width = width,
            .height = height,
            .x = x,
            .y = y,
            .content = content,
        };
    }
};

test "simple single pane" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0,42");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);
    try testing.expectEqual(42, layout.content.pane);
}

test "single pane with offset" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "40x12,10,5,7");
    try testing.expectEqual(40, layout.width);
    try testing.expectEqual(12, layout.height);
    try testing.expectEqual(10, layout.x);
    try testing.expectEqual(5, layout.y);
    try testing.expectEqual(7, layout.content.pane);
}

test "single pane large values" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "1920x1080,100,200,999");
    try testing.expectEqual(1920, layout.width);
    try testing.expectEqual(1080, layout.height);
    try testing.expectEqual(100, layout.x);
    try testing.expectEqual(200, layout.y);
    try testing.expectEqual(999, layout.content.pane);
}

test "horizontal split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0,2}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.horizontal;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(40, children[0].width);
    try testing.expectEqual(24, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(40, children[1].width);
    try testing.expectEqual(24, children[1].height);
    try testing.expectEqual(40, children[1].x);
    try testing.expectEqual(0, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "vertical split two panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12,2]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);
    try testing.expectEqual(0, layout.x);
    try testing.expectEqual(0, layout.y);

    const children = layout.content.vertical;
    try testing.expectEqual(2, children.len);

    try testing.expectEqual(80, children[0].width);
    try testing.expectEqual(12, children[0].height);
    try testing.expectEqual(0, children[0].x);
    try testing.expectEqual(0, children[0].y);
    try testing.expectEqual(1, children[0].content.pane);

    try testing.expectEqual(80, children[1].width);
    try testing.expectEqual(12, children[1].height);
    try testing.expectEqual(0, children[1].x);
    try testing.expectEqual(12, children[1].y);
    try testing.expectEqual(2, children[1].content.pane);
}

test "horizontal split three panes" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const layout: Layout = try .parse(arena.allocator(), "120x24,0,0{40x24,0,0,1,40x24,40,0,2,40x24,80,0,3}");
    try testing.expectEqual(120, layout.width);
    try testing.expectEqual(24, layout.height);

    const children = layout.content.horizontal;
    try testing.expectEqual(3, children.len);
    try testing.expectEqual(1, children[0].content.pane);
    try testing.expectEqual(2, children[1].content.pane);
    try testing.expectEqual(3, children[2].content.pane);
}

test "nested horizontal in vertical" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Vertical split with top pane and bottom horizontal split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0[80x12,0,0,1,80x12,0,12{40x12,0,12,2,40x12,40,12,3}]");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const vert_children = layout.content.vertical;
    try testing.expectEqual(2, vert_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, vert_children[0].content.pane);

    // Second child is a horizontal split
    const horiz_children = vert_children[1].content.horizontal;
    try testing.expectEqual(2, horiz_children.len);
    try testing.expectEqual(2, horiz_children[0].content.pane);
    try testing.expectEqual(3, horiz_children[1].content.pane);
}

test "nested vertical in horizontal" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Horizontal split with left pane and right vertical split
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0,1,40x24,40,0[40x12,40,0,2,40x12,40,12,3]}");
    try testing.expectEqual(80, layout.width);
    try testing.expectEqual(24, layout.height);

    const horiz_children = layout.content.horizontal;
    try testing.expectEqual(2, horiz_children.len);

    // First child is a simple pane
    try testing.expectEqual(1, horiz_children[0].content.pane);

    // Second child is a vertical split
    const vert_children = horiz_children[1].content.vertical;
    try testing.expectEqual(2, vert_children.len);
    try testing.expectEqual(2, vert_children[0].content.pane);
    try testing.expectEqual(3, vert_children[1].content.pane);
}

test "deeply nested layout" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Three levels deep
    const layout: Layout = try .parse(arena.allocator(), "80x24,0,0{40x24,0,0[40x12,0,0,1,40x12,0,12,2],40x24,40,0,3}");

    const horiz = layout.content.horizontal;
    try testing.expectEqual(2, horiz.len);

    const vert = horiz[0].content.vertical;
    try testing.expectEqual(2, vert.len);
    try testing.expectEqual(1, vert[0].content.pane);
    try testing.expectEqual(2, vert[1].content.pane);

    try testing.expectEqual(3, horiz[1].content.pane);
}

test "syntax error empty string" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), ""));
}

test "syntax error missing width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "x24,0,0,1"));
}

test "syntax error missing height" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x,0,0,1"));
}

test "syntax error missing x" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,,0,1"));
}

test "syntax error missing y" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,,1"));
}

test "syntax error missing pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,"));
}

test "syntax error non-numeric width" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "abcx24,0,0,1"));
}

test "syntax error non-numeric pane id" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,abc"));
}

test "syntax error unclosed horizontal bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1"));
}

test "syntax error unclosed vertical bracket" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1"));
}

test "syntax error mismatched brackets" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0{40x24,0,0,1]"));
    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0[40x24,0,0,1}"));
}

test "syntax error trailing data" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0,1extra"));
}

test "syntax error no x separator" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "8024,0,0,1"));
}

test "syntax error no content delimiter" {
    var arena: ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    try testing.expectError(error.SyntaxError, Layout.parse(arena.allocator(), "80x24,0,0"));
}
