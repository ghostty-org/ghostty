/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
const build_options = @import("terminal_options");
const oni = @import("oniguruma");
const point = @import("point.zig");
const Selection = @import("Selection.zig");
const Screen = @import("Screen.zig");
const Pin = @import("PageList.zig").Pin;
const Allocator = std.mem.Allocator;

string: [:0]const u8,
map: []Pin,

pub fn deinit(self: StringMap, alloc: Allocator) void {
    alloc.free(self.string);
    alloc.free(self.map);
}

/// Returns an iterator that yields the next match of the given regex.
/// Requires Ghostty to be compiled with regex support.
pub const searchIterator = if (build_options.oniguruma)
    searchIteratorOni
else
    void;

fn searchIteratorOni(
    self: StringMap,
    regex: oni.Regex,
) SearchIterator {
    return .{ .map = self, .regex = regex };
}

/// Iterates over the regular expression matches of the string.
pub const SearchIterator = struct {
    map: StringMap,
    regex: oni.Regex,
    offset: usize = 0,

    /// Returns the next regular expression match or null if there are
    /// no more matches.
    pub fn next(self: *SearchIterator) !?Match {
        if (self.offset >= self.map.string.len) return null;

        var region = self.regex.search(
            self.map.string[self.offset..],
            .{},
        ) catch |err| switch (err) {
            error.Mismatch => {
                self.offset = self.map.string.len;
                return null;
            },

            else => return err,
        };
        errdefer region.deinit();

        // Increment our offset by the number of bytes in the match.
        // We defer this so that we can return the match before
        // modifying the offset.
        const end_idx: usize = @intCast(region.ends()[0]);
        defer self.offset += end_idx;

        return .{
            .map = self.map,
            .offset = self.offset,
            .region = region,
        };
    }
};

/// A single regular expression match.
pub const Match = struct {
    map: StringMap,
    offset: usize,
    region: oni.Region,

    pub fn deinit(self: *Match) void {
        self.region.deinit();
    }

    /// Returns the selection containing the full match.
    pub fn selection(self: Match) Selection {
        const start_idx: usize = @intCast(self.region.starts()[0]);
        const end_idx: usize = @intCast(self.region.ends()[0] - 1);
        const start_pt = self.map.map[self.offset + start_idx];
        const end_pt = self.map.map[self.offset + end_idx];
        return .init(start_pt, end_pt, false);
    }

    /// Returns the number of capture groups (including group 0 = full match).
    pub fn groupCount(self: Match) usize {
        return self.region.count();
    }

    /// Returns the string slice for a capture group (0 = full match, 1+ = groups).
    /// Returns null if the group index is out of bounds or the group was unmatched.
    pub fn group(self: Match, idx: usize) ?[]const u8 {
        if (idx >= self.region.count()) return null;
        const start: c_int = self.region.starts()[idx];
        const end: c_int = self.region.ends()[idx];
        if (start < 0 or end < 0) return null; // unmatched optional group
        const start_usize: usize = @intCast(start);
        const end_usize: usize = @intCast(end);
        return self.map.string[self.offset + start_usize .. self.offset + end_usize];
    }
};

test "StringMap searchIterator" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        "[A-B]{2}",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen
    var s = try Screen.init(alloc, .{ .cols = 5, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    const str = "1ABCD2EFGH\n3IJKL";
    try s.testWriteString(str);
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 2,
            .y = 1,
        } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Get our iterator
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 1,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 2,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL detection" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com/path world");

    // Get the line
    const line = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{
            .x = 10,
            .y = 0,
        } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Search for URL match
    var it = map.searchIterator(re);
    {
        var match = (try it.next()).?;
        defer match.deinit();

        const sel = match.selection();
        // URL should start at x=6 ("https://example.com/path" starts after "hello ")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 6,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.start()).?);
        // URL should end at x=29 (end of "/path")
        try testing.expectEqual(point.Point{ .screen = .{
            .x = 29,
            .y = 0,
        } }, s.pages.pointFromPin(.screen, sel.end()).?);
    }

    try testing.expect(try it.next() == null);
}

test "StringMap searchIterator URL with click position" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;
    const url = @import("../config/url.zig");

    // Initialize URL regex
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        url.regex,
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen with text containing a URL
    var s = try Screen.init(alloc, .{ .cols = 40, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("hello https://example.com world");

    // Simulate clicking on "example" (x=14)
    const click_pin = s.pages.pin(.{ .active = .{
        .x = 14,
        .y = 0,
    } }).?;

    // Get the line
    const line = s.selectLine(.{
        .pin = click_pin,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Search for URL match and verify click position is within URL
    var it = map.searchIterator(re);
    var found_url = false;
    while (true) {
        var match = (try it.next()) orelse break;
        defer match.deinit();

        const sel = match.selection();
        if (sel.contains(&s, click_pin)) {
            found_url = true;
            // Verify URL bounds
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 6,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.start()).?);
            try testing.expectEqual(point.Point{ .screen = .{
                .x = 24,
                .y = 0,
            } }, s.pages.pointFromPin(.screen, sel.end()).?);
            break;
        }
    }
    try testing.expect(found_url);
}

test "Match group extraction" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize our regex with capture groups: JIRA-(\d+)
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        "JIRA-(\\d+)",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen
    var s = try Screen.init(alloc, .{ .cols = 20, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("Check JIRA-1234 now");

    const line_sel = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line_sel,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    // Search for match
    var it = map.searchIterator(re);
    var match = (try it.next()).?;
    defer match.deinit();

    // Group 0 = full match "JIRA-1234"
    try testing.expectEqualStrings("JIRA-1234", match.group(0).?);
    // Group 1 = first capture group "1234"
    try testing.expectEqualStrings("1234", match.group(1).?);
    // Group 2 = out of bounds
    try testing.expect(match.group(2) == null);
    // Group count should be 2 (group 0 + group 1)
    try testing.expectEqual(@as(usize, 2), match.groupCount());
}

test "Match group with optional groups" {
    if (comptime !build_options.oniguruma) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Initialize regex with optional group: (foo)?(bar)
    try oni.testing.ensureInit();
    var re = try oni.Regex.init(
        "(foo)?(bar)",
        .{},
        oni.Encoding.utf8,
        oni.Syntax.default,
        null,
    );
    defer re.deinit();

    // Initialize our screen - "bar" without "foo"
    var s = try Screen.init(alloc, .{ .cols = 10, .rows = 5, .max_scrollback = 0 });
    defer s.deinit();
    try s.testWriteString("bar");

    const line_sel = s.selectLine(.{
        .pin = s.pages.pin(.{ .active = .{ .x = 0, .y = 0 } }).?,
    }).?;
    var map: StringMap = undefined;
    const sel_str = try s.selectionString(alloc, .{
        .sel = line_sel,
        .trim = false,
        .map = &map,
    });
    alloc.free(sel_str);
    defer map.deinit(alloc);

    var it = map.searchIterator(re);
    var match = (try it.next()).?;
    defer match.deinit();

    // Group 0 = full match "bar"
    try testing.expectEqualStrings("bar", match.group(0).?);
    // Group 1 = optional "foo" - not matched
    try testing.expect(match.group(1) == null);
    // Group 2 = "bar"
    try testing.expectEqualStrings("bar", match.group(2).?);
}
