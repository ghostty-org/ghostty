const std = @import("std");
const Allocator = std.mem.Allocator;
const oni = @import("oniguruma");
const configpkg = @import("../config.zig");
const inputpkg = @import("../input.zig");
const internal_os = @import("../os/main.zig");
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

/// A link match that stores the selection, link type, and prepared URL.
/// URLs are trimmed (for regex matches) and expanded (tilde paths) during matching
/// so the UI layer receives ready-to-open URLs.
pub const LinkMatch = struct {
    /// The selection coordinates of the match in the terminal
    selection: terminal.Selection,

    /// Whether this is an OSC8 hyperlink (true) or regex-detected URL (false)
    is_osc8: bool,

    /// The prepared URL ready to open (trimmed and tilde-expanded as needed)
    url: []const u8,
};

/// Helper to trim trailing punctuation and line/column numbers from file paths.
/// For file paths (~/..., /..., ../..., ./...), strips :line and :line:col patterns.
/// For URLs with schemes (http://, ssh://, etc.), only removes trailing punctuation
/// to preserve port numbers like :8080.
fn trimTrailingPunctuation(url: []const u8) []const u8 {
    var result = url;

    // Check if this is a URL with a scheme (contains ://)
    const has_scheme = has_scheme: {
        for (0..result.len) |i| {
            if (i + 2 < result.len and
                result[i] == ':' and
                result[i + 1] == '/' and
                result[i + 2] == '/')
            {
                break :has_scheme true;
            }
        }
        break :has_scheme false;
    };

    // Only strip line/column numbers from file paths (not URLs with schemes)
    if (!has_scheme) {
        // Strip line/column numbers (e.g., :42 or :42:10)
        // Work backwards to handle :line:col pattern
        for (0..2) |_| {
            if (result.len == 0) break;

            // Find the last colon
            var last_colon: ?usize = null;
            for (0..result.len) |i| {
                if (result[i] == ':') last_colon = i;
            }

            if (last_colon) |colon_pos| {
                // Check if everything after the colon is digits
                const after_colon = result[colon_pos + 1 ..];
                if (after_colon.len > 0) {
                    var all_digits = true;
                    for (after_colon) |c| {
                        if (c < '0' or c > '9') {
                            all_digits = false;
                            break;
                        }
                    }

                    if (all_digits) {
                        result = result[0..colon_pos];
                        continue;
                    }
                }
            }
            break;
        }
    }

    // Now strip trailing punctuation (for all URLs)
    while (result.len > 0) {
        const last = result[result.len - 1];
        if (last == '.' or last == ',' or last == ';' or last == ':') {
            result = result[0 .. result.len - 1];
        } else {
            break;
        }
    }

    return result;
}

/// Prepare a URL for use by trimming (if needed) and expanding tilde paths.
/// For OSC8 links (is_osc8=true), the URL is kept intact except for tilde expansion.
/// For regex-detected links (is_osc8=false), trailing punctuation and line numbers are trimmed first.
/// Returns an allocated copy of the prepared URL.
fn prepareUrl(alloc: Allocator, url: []const u8, is_osc8: bool) ![]const u8 {
    // OSC8 links are authoritative - never trim them
    // Regex-detected links need trimming to handle punctuation and line numbers
    const to_expand = if (!is_osc8)
        trimTrailingPunctuation(url)
    else
        url;

    // Expand tilde paths
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const expanded = internal_os.expandHome(to_expand, &path_buf) catch to_expand;

    // Return owned copy
    return try alloc.dupe(u8, expanded);
}

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
        mouse_vp_pt: point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !MatchSet {
        // Convert the viewport point to a screen point.
        const mouse_pin = screen.pages.pin(.{
            .viewport = mouse_vp_pt,
        }) orelse return .{};

        // This contains our list of matches. The matches are stored
        // as LinkMatch structs with just coordinates and type.
        // No expansion happens here to keep this hot path fast.
        var matches: std.ArrayList(LinkMatch) = .empty;
        defer {
            // Free all URLs in case we're unwinding before toOwnedSlice
            for (matches.items) |match| {
                alloc.free(match.url);
            }
            matches.deinit(alloc);
        }

        // If our mouse is over an OSC8 link, then we can skip the regex
        // matches below since OSC8 takes priority.
        try self.matchSetFromOSC8(
            alloc,
            &matches,
            screen,
            mouse_pin,
            mouse_mods,
        );

        // If we have no matches then we can try the regex matches.
        if (matches.items.len == 0) {
            try self.matchSetFromLinks(
                alloc,
                &matches,
                screen,
                mouse_pin,
                mouse_mods,
            );
        }

        const owned_matches = try matches.toOwnedSlice(alloc);
        // Success! Ownership transferred, so clear items to prevent defer from freeing
        return .{ .matches = owned_matches };
    }

    /// Fast lookup for a single link under a specific pin.
    /// Returns immediately upon finding a match without building the full match set.
    /// This is more efficient for hover/click detection than matchSet().
    pub fn matchForPin(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_vp_pt: point.Coordinate,
        mouse_mods: inputpkg.Mods,
    ) !?LinkMatch {
        // Convert the viewport point to a screen point.
        const mouse_pin = screen.pages.pin(.{
            .viewport = mouse_vp_pt,
        }) orelse return null;

        // Check for OSC8 link first (takes priority)
        if (try self.matchForPinOSC8(alloc, screen, mouse_pin, mouse_mods)) |match| {
            return match;
        }

        // No OSC8 match, try regex links
        return try self.matchForPinLinks(alloc, screen, mouse_pin, mouse_mods);
    }

    fn matchSetFromOSC8(
        self: *const Set,
        alloc: Allocator,
        matches: *std.ArrayList(LinkMatch),
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // If the right mods aren't pressed, then we can't match.
        if (!mouse_mods.equal(inputpkg.ctrlOrSuper(.{}))) return;

        // Check if the cell the mouse is over is an OSC8 hyperlink
        const mouse_cell = mouse_pin.rowAndCell().cell;
        if (!mouse_cell.hyperlink) return;

        // Get our hyperlink entry
        const page: *terminal.Page = &mouse_pin.node.data;
        const link_id = page.lookupHyperlink(mouse_cell) orelse {
            log.warn("failed to find hyperlink for cell", .{});
            return;
        };
        const link = page.hyperlink_set.get(page.memory, link_id);

        // Extract and prepare the URI once for all matches
        const uri = link.uri.offset.ptr(page.memory)[0..link.uri.len];
        const prepared_url = try prepareUrl(alloc, uri, true); // true = OSC8 link
        errdefer alloc.free(prepared_url);

        // If our link has an implicit ID (no ID set explicitly via OSC8)
        // then we use an alternate matching technique that iterates forward
        // and backward until it finds boundaries. The Implicit function takes
        // ownership of prepared_url.
        if (link.id == .implicit) {
            return try self.matchSetFromOSC8Implicit(
                alloc,
                matches,
                mouse_pin,
                prepared_url,
            );
        }
        // errdefer no longer needed here since we duplicate for each match below
        // and free the original at the end

        // Go through every row and find matching hyperlinks for the given ID.
        // Note the link ID is not the same as the OSC8 ID parameter. But
        // we hash hyperlinks by their contents which should achieve the same
        // thing so we can use the ID as a key.
        var current: ?terminal.Selection = null;
        var row_it = screen.pages.getTopLeft(.viewport).rowIterator(.right_down, null);
        while (row_it.next()) |row_pin| {
            const row = row_pin.rowAndCell().row;

            // If the row doesn't have any hyperlinks then we're done
            // building our matching selection.
            if (!row.hyperlink) {
                if (current) |sel| {
                    const url_copy = try alloc.dupe(u8, prepared_url);
                    errdefer alloc.free(url_copy);
                    try matches.append(alloc, .{
                        .selection = sel,
                        .is_osc8 = true,
                        .url = url_copy,
                    });
                    current = null;
                }

                continue;
            }

            // We have hyperlinks, look for our own matching hyperlink.
            for (row_pin.cells(.right), 0..) |*cell, x| {
                const match = match: {
                    if (cell.hyperlink) {
                        if (row_pin.node.data.lookupHyperlink(cell)) |cell_link_id| {
                            break :match cell_link_id == link_id;
                        }
                    }
                    break :match false;
                };

                // If we have a match, extend our selection or start a new
                // selection.
                if (match) {
                    const cell_pin = row_pin.right(x);
                    if (current) |*sel| {
                        sel.endPtr().* = cell_pin;
                    } else {
                        current = .init(
                            cell_pin,
                            cell_pin,
                            false,
                        );
                    }

                    continue;
                }

                // No match, if we have a current selection then complete it.
                if (current) |sel| {
                    const url_copy = try alloc.dupe(u8, prepared_url);
                    errdefer alloc.free(url_copy);
                    try matches.append(alloc, .{
                        .selection = sel,
                        .is_osc8 = true,
                        .url = url_copy,
                    });
                    current = null;
                }
            }
        }

        // Complete any remaining selection
        if (current) |sel| {
            const url_copy = try alloc.dupe(u8, prepared_url);
            errdefer alloc.free(url_copy);
            try matches.append(alloc, .{
                .selection = sel,
                .is_osc8 = true,
                .url = url_copy,
            });
        }

        // Free the original prepared_url since we duplicated it for each match
        alloc.free(prepared_url);
    }

    /// Match OSC8 links around the mouse pin for an OSC8 link with an
    /// implicit ID. This only matches cells with the same URI directly
    /// around the mouse pin.
    fn matchSetFromOSC8Implicit(
        self: *const Set,
        alloc: Allocator,
        matches: *std.ArrayList(LinkMatch),
        mouse_pin: terminal.Pin,
        prepared_url: []const u8,
    ) !void {
        _ = self;

        // Get the URI from the cell under the mouse so we can match against it
        const page: *terminal.Page = &mouse_pin.node.data;
        const mouse_cell = mouse_pin.rowAndCell().cell;
        const link_id = page.lookupHyperlink(mouse_cell) orelse return;
        const link = page.hyperlink_set.get(page.memory, link_id);
        const uri = link.uri.offset.ptr(page.memory)[0..link.uri.len];

        // Our selection starts with just our pin.
        var sel = terminal.Selection.init(mouse_pin, mouse_pin, false);

        // Expand it to the left.
        var it = mouse_pin.cellIterator(.left_up, null);
        while (it.next()) |cell_pin| {
            const cell_page: *terminal.Page = &cell_pin.node.data;
            const rac = cell_pin.rowAndCell();
            const cell = rac.cell;

            // If this cell isn't a hyperlink then we've found a boundary
            if (!cell.hyperlink) break;

            const cell_link_id = cell_page.lookupHyperlink(cell) orelse {
                log.warn("failed to find hyperlink for cell", .{});
                break;
            };
            const cell_link = cell_page.hyperlink_set.get(cell_page.memory, cell_link_id);

            // If this link has an explicit ID then we found a boundary
            if (cell_link.id != .implicit) break;

            // If this link has a different URI then we found a boundary
            const cell_uri = cell_link.uri.offset.ptr(cell_page.memory)[0..cell_link.uri.len];
            if (!std.mem.eql(u8, uri, cell_uri)) break;

            sel.startPtr().* = cell_pin;
        }

        // Expand it to the right
        it = mouse_pin.cellIterator(.right_down, null);
        while (it.next()) |cell_pin| {
            const cell_page: *terminal.Page = &cell_pin.node.data;
            const rac = cell_pin.rowAndCell();
            const cell = rac.cell;

            // If this cell isn't a hyperlink then we've found a boundary
            if (!cell.hyperlink) break;

            const cell_link_id = cell_page.lookupHyperlink(cell) orelse {
                log.warn("failed to find hyperlink for cell", .{});
                break;
            };
            const cell_link = cell_page.hyperlink_set.get(cell_page.memory, cell_link_id);

            // If this link has an explicit ID then we found a boundary
            if (cell_link.id != .implicit) break;

            // If this link has a different URI then we found a boundary
            const cell_uri = cell_link.uri.offset.ptr(cell_page.memory)[0..cell_link.uri.len];
            if (!std.mem.eql(u8, uri, cell_uri)) break;

            sel.endPtr().* = cell_pin;
        }

        try matches.append(alloc, .{
            .selection = sel,
            .is_osc8 = true,
            .url = prepared_url,
        });
    }

    /// Fast OSC8 link lookup for a single pin. Returns immediately if found.
    fn matchForPinOSC8(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !?LinkMatch {
        _ = self;
        _ = screen;

        // Only check OSC8 if we have the right modifiers
        if (!mouse_mods.equal(inputpkg.ctrlOrSuper(.{}))) return null;

        const rac = mouse_pin.rowAndCell();
        const cell = rac.cell;
        if (!cell.hyperlink) return null;

        const page: *terminal.Page = &mouse_pin.node.data;
        const link_id = page.lookupHyperlink(cell) orelse return null;
        const link = page.hyperlink_set.get(page.memory, link_id);

        // Extract and prepare the URI
        const uri = link.uri.offset.ptr(page.memory)[0..link.uri.len];
        const prepared_url = try prepareUrl(alloc, uri, true); // true = OSC8 link

        // For implicit IDs, we need to find the selection boundaries
        if (link.id == .implicit) {
            var sel = terminal.Selection.init(mouse_pin, mouse_pin, false);

            // Expand left
            var it = mouse_pin.cellIterator(.left_up, null);
            while (it.next()) |cell_pin| {
                const cell_page: *terminal.Page = &cell_pin.node.data;
                const cell_rac = cell_pin.rowAndCell();
                const cell_cell = cell_rac.cell;
                if (!cell_cell.hyperlink) break;

                const cell_link_id = cell_page.lookupHyperlink(cell_cell) orelse break;
                const cell_link = cell_page.hyperlink_set.get(cell_page.memory, cell_link_id);
                if (cell_link.id != .implicit) break;

                const cell_uri = cell_link.uri.offset.ptr(cell_page.memory)[0..cell_link.uri.len];
                if (!std.mem.eql(u8, uri, cell_uri)) break;

                sel.startPtr().* = cell_pin;
            }

            // Expand right
            it = mouse_pin.cellIterator(.right_down, null);
            while (it.next()) |cell_pin| {
                const cell_page: *terminal.Page = &cell_pin.node.data;
                const cell_rac = cell_pin.rowAndCell();
                const cell_cell = cell_rac.cell;
                if (!cell_cell.hyperlink) break;

                const cell_link_id = cell_page.lookupHyperlink(cell_cell) orelse break;
                const cell_link = cell_page.hyperlink_set.get(cell_page.memory, cell_link_id);
                if (cell_link.id != .implicit) break;

                const cell_uri = cell_link.uri.offset.ptr(cell_page.memory)[0..cell_link.uri.len];
                if (!std.mem.eql(u8, uri, cell_uri)) break;

                sel.endPtr().* = cell_pin;
            }

            return .{
                .selection = sel,
                .is_osc8 = true,
                .url = prepared_url,
            };
        }

        // For explicit IDs, just return a single-cell selection
        const sel = terminal.Selection.init(mouse_pin, mouse_pin, false);
        return .{
            .selection = sel,
            .is_osc8 = true,
            .url = prepared_url,
        };
    }

    /// Fast regex link lookup for a single pin. Returns immediately if found.
    fn matchForPinLinks(
        self: *const Set,
        alloc: Allocator,
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !?LinkMatch {
        // Get just the line containing the mouse pin
        const line_sel = screen.selectLine(.{
            .pin = mouse_pin,
            .whitespace = null,
            .semantic_prompt_boundary = false,
        }) orelse return null;

        const strmap: terminal.StringMap = strmap: {
            var strmap: terminal.StringMap = undefined;
            const str = screen.selectionString(alloc, .{
                .sel = line_sel,
                .trim = false,
                .map = &strmap,
            }) catch return null;
            alloc.free(str);
            break :strmap strmap;
        };
        defer strmap.deinit(alloc);

        // Check each configured link
        for (self.links) |link| {
            // Check highlight conditions
            switch (link.highlight) {
                .always => {},
                .always_mods => |v| if (!mouse_mods.equal(v)) continue,
                .hover => {},
                .hover_mods => |v| if (!mouse_mods.equal(v)) continue,
            }

            // Search for matches
            var it = strmap.searchIterator(link.regex);
            while (true) {
                const match_ = it.next() catch break;
                var match = match_ orelse break;
                defer match.deinit();
                const sel = match.selection();

                // For hover links, only match if pin is contained
                switch (link.highlight) {
                    .always, .always_mods => {},
                    .hover, .hover_mods => if (!sel.contains(screen, mouse_pin)) continue,
                }

                // Check if this match contains our pin
                if (!sel.contains(screen, mouse_pin)) continue;

                // Found a match! Extract and prepare
                const url_text = try screen.selectionString(alloc, .{
                    .sel = sel,
                    .trim = false,
                });
                defer alloc.free(url_text);

                const prepared_url = try prepareUrl(alloc, url_text, false); // false = regex link

                return .{
                    .selection = sel,
                    .is_osc8 = false,
                    .url = prepared_url,
                };
            }
        }

        return null;
    }

    /// Fills matches with the matches from regex link matches.
    fn matchSetFromLinks(
        self: *const Set,
        alloc: Allocator,
        matches: *std.ArrayList(LinkMatch),
        screen: *Screen,
        mouse_pin: terminal.Pin,
        mouse_mods: inputpkg.Mods,
    ) !void {
        // Iterate over all the visible lines.
        var lineIter = screen.lineIterator(screen.pages.pin(.{
            .viewport = .{},
        }) orelse return);
        while (lineIter.next()) |line_sel| {
            const strmap: terminal.StringMap = strmap: {
                var strmap: terminal.StringMap = undefined;
                const str = screen.selectionString(alloc, .{
                    .sel = line_sel,
                    .trim = false,
                    .map = &strmap,
                }) catch |err| {
                    log.warn(
                        "failed to build string map for link checking err={}",
                        .{err},
                    );
                    continue;
                };
                alloc.free(str);
                break :strmap strmap;
            };
            defer strmap.deinit(alloc);

            // Go through each link and see if we have any matches.
            for (self.links) |link| {
                // Determine if our highlight conditions are met. We use a
                // switch here instead of an if so that we can get a compile
                // error if any other conditions are added.
                switch (link.highlight) {
                    .always => {},
                    .always_mods => |v| if (!mouse_mods.equal(v)) continue,
                    inline .hover, .hover_mods => |v, tag| {
                        if (!line_sel.contains(screen, mouse_pin)) continue;
                        if (comptime tag == .hover_mods) {
                            if (!mouse_mods.equal(v)) continue;
                        }
                    },
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
                    switch (link.highlight) {
                        .always, .always_mods => {},
                        .hover,
                        .hover_mods,
                        => if (!sel.contains(screen, mouse_pin)) continue,
                    }

                    // Extract selection text and prepare it
                    const url_text = try screen.selectionString(alloc, .{
                        .sel = sel,
                        .trim = false,
                    });
                    defer alloc.free(url_text);

                    const prepared_url = try prepareUrl(alloc, url_text, false); // false = regex link
                    errdefer alloc.free(prepared_url);

                    // Store the selection, URL, and mark as regex (not OSC8)
                    try matches.append(alloc, .{
                        .selection = sel,
                        .is_osc8 = false,
                        .url = prepared_url,
                    });
                }
            }
        }
    }
};

/// MatchSet is the result of matching links against a screen. This contains
/// all the matching links and operations on them such as whether a specific
/// cell is part of a matched link.
pub const MatchSet = struct {
    /// The lightweight matches (just selections and link type).
    ///
    /// Important: this must be in left-to-right top-to-bottom order.
    matches: []const LinkMatch = &.{},
    i: usize = 0,

    pub fn deinit(self: *MatchSet, alloc: Allocator) void {
        // Free URL memory for each match
        for (self.matches) |match| {
            alloc.free(match.url);
        }
        alloc.free(self.matches);
    }

    /// Checks if the matchset contains the given pin. This is slower than
    /// orderedContains but is stateless and more flexible since it doesn't
    /// require the points to be in order.
    pub fn contains(
        self: *MatchSet,
        screen: *const Screen,
        pin: terminal.Pin,
    ) bool {
        for (self.matches) |match| {
            if (match.selection.contains(screen, pin)) return true;
        }

        return false;
    }

    /// Checks if the matchset contains the given pt. The points must be
    /// given in left-to-right top-to-bottom order. This is a stateful
    /// operation and giving a point out of order can cause invalid
    /// results.
    pub fn orderedContains(
        self: *MatchSet,
        screen: *const Screen,
        pin: terminal.Pin,
    ) bool {
        // If we're beyond the end of our possible matches, we're done.
        if (self.i >= self.matches.len) return false;

        // If our selection ends before the point, then no point will ever
        // again match this selection so we move on to the next one.
        while (self.matches[self.i].selection.end().before(pin)) {
            self.i += 1;
            if (self.i >= self.matches.len) return false;
        }

        return self.matches[self.i].selection.contains(screen, pin);
    }

    /// Returns the LinkMatch for the given pin, if any.
    /// The caller can use this to extract the URL and determine link type.
    pub fn matchForPin(
        self: *const MatchSet,
        screen: *const Screen,
        pin: terminal.Pin,
    ) ?*const LinkMatch {
        for (self.matches) |*match| {
            if (match.selection.contains(screen, pin)) return match;
        }
        return null;
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
    var match = try set.matchSet(alloc, &s, .{}, .{});
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 2), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 0,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 1,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 2,
    } }).?));
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
        var match = try set.matchSet(alloc, &s, .{}, .{});
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 1), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 3,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 2,
        } }).?));
    }

    // Hovering over the first link
    {
        var match = try set.matchSet(alloc, &s, .{ .x = 1, .y = 0 }, .{});
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 2), match.matches.len);

        // Test our matches
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 0,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 2,
            .y = 0,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 3,
            .y = 0,
        } }).?));
        try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 1,
        } }).?));
        try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
            .x = 1,
            .y = 2,
        } }).?));
    }
}

test "matchset mods no match" {
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
            .highlight = .{ .always_mods = .{ .ctrl = true } },
        },
    });
    defer set.deinit(alloc);

    // Get our matches
    var match = try set.matchSet(alloc, &s, .{}, .{});
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 0,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 1,
    } }).?));
    try testing.expect(!match.orderedContains(&s, s.pages.pin(.{ .screen = .{
        .x = 1,
        .y = 2,
    } }).?));
}

test "matchset osc8" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our terminal
    var t = try Terminal.init(alloc, .{ .cols = 10, .rows = 10 });
    defer t.deinit(alloc);
    const s = &t.screen;

    try t.printString("ABC");
    try t.screen.startHyperlink("http://example.com", null);
    try t.printString("123");
    t.screen.endHyperlink();

    // Get a set
    var set = try Set.fromConfig(alloc, &.{});
    defer set.deinit(alloc);

    // No matches over the non-link
    {
        var match = try set.matchSet(
            alloc,
            &t.screen,
            .{ .x = 2, .y = 0 },
            inputpkg.ctrlOrSuper(.{}),
        );
        defer match.deinit(alloc);
        try testing.expectEqual(@as(usize, 0), match.matches.len);
    }

    // Match over link
    var match = try set.matchSet(
        alloc,
        &t.screen,
        .{ .x = 3, .y = 0 },
        inputpkg.ctrlOrSuper(.{}),
    );
    defer match.deinit(alloc);
    try testing.expectEqual(@as(usize, 1), match.matches.len);

    // Test our matches
    try testing.expect(!match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 2,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 3,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 4,
        .y = 0,
    } }).?));
    try testing.expect(match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 5,
        .y = 0,
    } }).?));
    try testing.expect(!match.orderedContains(s, s.pages.pin(.{ .screen = .{
        .x = 6,
        .y = 0,
    } }).?));
}
