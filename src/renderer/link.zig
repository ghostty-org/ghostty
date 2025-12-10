const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;
const Terminal = terminal.Terminal;

const log = std.log.scoped(.renderer_link);

/// The link configuration needed for renderers.
pub const Link = struct {
    /// The regular expression to match the link against.
    regex: oni.Regex,

    /// The situations in which the link should be highlighted.
    highlight: inputpkg.Link.Highlight,

    pub fn deinit(self: *Link) void {
        self.regex.deinit();
    }
};

/// A set of links. This provides a higher level API for renderers
/// to match against a viewport and determine if cells are part of
/// a link.
pub const Set = struct {
    links: []Link,

    /// Returns the slice of links from the configuration.
    pub fn fromConfig(
        alloc: Allocator,
        config: []const inputpkg.Link,
    ) !Set {
        var links: std.ArrayList(Link) = .empty;
        defer links.deinit(alloc);

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(alloc, .{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice(alloc) };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Fills matches with the matches from regex link matches.
    pub fn renderCellMap(
        self: *const Set,
        alloc: Allocator,
        result: *terminal.RenderState.CellSet,
        render_state: *const terminal.RenderState,
        mouse_viewport: ?point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Fast path, not very likely since we have default links.
        if (self.links.len == 0) return;

        // Convert our render state to a string + byte map.
        var builder: std.Io.Writer.Allocating = .init(alloc);
        defer builder.deinit();
        var map: terminal.RenderState.StringMap = .empty;
        defer map.deinit(alloc);
        try render_state.string(&builder.writer, .{
            .alloc = alloc,
            .map = &map,
        });

        const str = builder.writer.buffered();

        // Go through each link and see if we have any matches.
        for (self.links) |*link| {
            // Determine if our highlight conditions are met. We use a
            // switch here instead of an if so that we can get a compile
            // error if any other conditions are added.
            switch (link.highlight) {
                .always => {},
                .always_mods => |v| if (!mouse_mods.equal(v)) continue,

                // We check the hover points later.
                .hover => if (mouse_viewport == null) continue,
                .hover_mods => |v| {
                    if (mouse_viewport == null) continue;
                    if (!mouse_mods.equal(v)) continue;
                },
            }

            var offset: usize = 0;
            while (offset < str.len) {
                var region = link.regex.search(
                    str[offset..],
                    .{},
                ) catch |err| switch (err) {
                    error.Mismatch => break,
                    else => return err,
                };
                defer region.deinit();

                // We have a match!
                const offset_start: usize = @intCast(region.starts()[0]);
                const offset_end: usize = @intCast(region.ends()[0]);
                const start = offset + offset_start;
                const end = offset + offset_end;

                // Increment our offset by the number of bytes in the match.
                // We defer this so that we can return the match before
                // modifying the offset.
                defer offset = end;

                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (mouse_viewport) |vp| {
                        for (map.items[start..end]) |pt| {
                            if (pt.eql(vp)) break;
                        } else continue;
                    } else continue,
                }

                // Record the match
                for (map.items[start..end]) |pt| {
                    try result.put(alloc, pt, {});
                }
            }
        }
    }
};

test "renderCellMap" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    try s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}

test "renderCellMap hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    try s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .hover = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },
    });
    defer set.deinit(alloc);

    // Not hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            null,
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var result: terminal.RenderState.CellSet = .empty;
        defer result.deinit(alloc);
        try set.renderCellMap(
            alloc,
            &result,
            &state,
            .{ .x = 1, .y = 0 },
            .{},
        );

        // Test our matches
        try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
        try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
        try testing.expect(result.contains(.{ .x = 1, .y = 1 }));
        try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
    }
}

test "renderCellMap mods no match" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var t: terminal.Terminal = try .init(alloc, .{
        .cols = 5,
        .rows = 3,
    });
    defer t.deinit(alloc);

    var s = t.vtStream();
    defer s.deinit();
    const str = "1ABCD2EFGH\r\n3IJKL";
    try s.nextSlice(str);

    var state: terminal.RenderState = .empty;
    defer state.deinit(alloc);
    try state.update(alloc, &t);

    // Get a set
    var set = try Set.fromConfig(alloc, &.{
        .{
            .regex = "AB",
            .action = .{ .open = {} },
            .highlight = .{ .always = {} },
        },

        .{
            .regex = "EF",
            .action = .{ .open = {} },
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var result: terminal.RenderState.CellSet = .empty;
    defer result.deinit(alloc);
    try set.renderCellMap(
        alloc,
        &result,
        &state,
        null,
        .{},
    );

    // Test our matches
    try testing.expect(!result.contains(.{ .x = 0, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 1, .y = 0 }));
    try testing.expect(result.contains(.{ .x = 2, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 3, .y = 0 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 1 }));
    try testing.expect(!result.contains(.{ .x = 1, .y = 2 }));
}
