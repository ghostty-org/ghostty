const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const configpkg = @import("../config.zig");
const inputpkg = @import("../input.zig");
const terminal = @import("../terminal/main.zig");
const point = terminal.point;
const Screen = terminal.Screen;

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
        var links = std.ArrayList(Link).init(alloc);
        defer links.deinit();

        for (config) |link| {
            var regex = try link.oniRegex();
            errdefer regex.deinit();
            try links.append(.{
                .regex = regex,
                .highlight = link.highlight,
            });
        }

        return .{ .links = try links.toOwnedSlice() };
    }

    pub fn deinit(self: *Set, alloc: Allocator) void {
        for (self.links) |*link| link.deinit();
        alloc.free(self.links);
    }

    /// Returns the matchset for the viewport state. The matchset is the
    /// full set of matching links for the visible viewport. A link
    /// only matches if it is also in the correct state (i.e. hovered
    /// if necessary).
    ///
    /// This is not a particularly efficient operation. This should be
    /// called sparingly.
    pub fn matchSet(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_vp_pt: point.Viewport,
    ) !MatchSet {
        // Convert the viewport point to a screen point.
        const mouse_pt = mouse_vp_pt.toScreen(screen);

        // This contains our list of matches. The matches are stored
        // as selections which contain the start and end points of
        // the match. There is no way to map these back to the link
        // configuration right now because we don't need to.
        var matches = std.ArrayList(terminal.Selection).init(alloc);
        defer matches.deinit();

        // Iterate over all the visible lines.
        var lineIter = screen.lineIterator(.viewport);
        while (lineIter.next()) |line| {
            const strmap = line.stringMap(alloc) catch |err| {
                log.warn(
                    "failed to build string map for link checking err={}",
                    .{err},
                );
                continue;
            };
            defer strmap.deinit(alloc);

            // Go through each link and see if we have any matches.
            for (self.links) |link| {
                // If this is a hover link and our mouse point isn't within
                // this line at all, we can skip it.
                if (link.highlight == .hover) {
                    if (!line.selection().contains(mouse_pt)) continue;
                }

                var it = strmap.searchIterator(link.regex);
                while (true) {
                    const match_ = it.next() catch |err| {
                        log.warn("failed to search for link err={}", .{err});
                        break;
                    };
                    var match = match_ orelse break;
                    defer match.deinit();
                    const sel = match.selection();

                    // If this is a highlight link then we only want to
                    // include matches that include our hover point.
                    if (link.highlight == .hover and
                        !sel.contains(mouse_pt))
                    {
                        continue;
                    }

                    try matches.append(sel);
                }
            }
        }

        return .{ .matches = try matches.toOwnedSlice() };
    }
};

/// MatchSet is the result of matching links against a screen. This contains
/// all the matching links and operations on them such as whether a specific
/// cell is part of a matched link.
pub const MatchSet = struct {
    /// The matches.
    ///
    /// Important: this must be in left-to-right top-to-bottom order.
    matches: []const terminal.Selection,
    i: usize = 0,

    pub fn deinit(self: *MatchSet, alloc: Allocator) void {
        alloc.free(self.matches);
    }

    /// Checks if the matchset contains the given pt. The points must be
    /// given in left-to-right top-to-bottom order. This is a stateful
    /// operation and giving a point out of order can cause invalid
    /// results.
    pub fn orderedContains(
        self: *MatchSet,
        pt: point.ScreenPoint,
    ) bool {
        // If we're beyond the end of our possible matches, we're done.
        if (self.i >= self.matches.len) return false;

        // If our selection ends before the point, then no point will ever
        // again match this selection so we move on to the next one.
        while (self.matches[self.i].end.before(pt)) {
            self.i += 1;
            if (self.i >= self.matches.len) return false;
        }

        return self.matches[self.i].contains(pt);
    }
};

test "matchset" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our screen
    var s = try Screen.init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

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
    var match = try set.matchSet(alloc, &s, .{});
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(.{ .x = 0, .y = 0 }));
    try testing.expect(match.orderedContains(.{ .x = 1, .y = 0 }));
    try testing.expect(match.orderedContains(.{ .x = 2, .y = 0 }));
    try testing.expect(!match.orderedContains(.{ .x = 3, .y = 0 }));
    try testing.expect(match.orderedContains(.{ .x = 1, .y = 1 }));
    try testing.expect(!match.orderedContains(.{ .x = 1, .y = 2 }));
}

test "matchset hover links" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our screen
    var s = try Screen.init(alloc, 5, 5, 0);
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);

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
        var match = try set.matchSet(alloc, &s, .{});
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(.{ .x = 0, .y = 0 }));
        try testing.expect(!match.orderedContains(.{ .x = 1, .y = 0 }));
        try testing.expect(!match.orderedContains(.{ .x = 2, .y = 0 }));
        try testing.expect(!match.orderedContains(.{ .x = 3, .y = 0 }));
        try testing.expect(match.orderedContains(.{ .x = 1, .y = 1 }));
        try testing.expect(!match.orderedContains(.{ .x = 1, .y = 2 }));
    }

    // Hovering over the first link
    {
        var match = try set.matchSet(alloc, &s, .{ .x = 1, .y = 0 });
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(.{ .x = 0, .y = 0 }));
        try testing.expect(match.orderedContains(.{ .x = 1, .y = 0 }));
        try testing.expect(match.orderedContains(.{ .x = 2, .y = 0 }));
        try testing.expect(!match.orderedContains(.{ .x = 3, .y = 0 }));
        try testing.expect(match.orderedContains(.{ .x = 1, .y = 1 }));
        try testing.expect(!match.orderedContains(.{ .x = 1, .y = 2 }));
    }
}
