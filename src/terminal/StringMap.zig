/// A string along with the mapping of each individual byte in the string
/// to the point in the screen.
const StringMap = @This();

const std = @import("std");
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
pub fn searchIterator(
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
};

test "StringMap searchIterator" {
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
    var s = try Screen.init(alloc, 5, 5, 0);
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
