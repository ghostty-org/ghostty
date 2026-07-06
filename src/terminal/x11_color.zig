const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const RGB = @import("color.zig").RGB;

/// A single X11 color entry.
pub const Entry = struct {
    /// Color name. Null-terminated so it can be exposed through the C API
    /// without runtime allocation.
    name: [:0]const u8,
    color: RGB,
};

/// All X11 colors in rgb.txt file order.
///
/// This is kept separate from `map` because the C API needs stable file order
/// and null-terminated names. `ColorMap` keys do not provide that contract.
pub const entries: []const Entry = entriesArray();

/// The map of all available X11 colors.
pub const map = colorMap();

pub const ColorMap = std.StaticStringMapWithEql(
    RGB,
    std.static_string_map.eqlAsciiIgnoreCase,
);

fn entriesArray() []const Entry {
    @setEvalBranchQuota(1_000_000);
    const len = std.mem.count(u8, data, "\n");
    var result: [len]Entry = undefined;
    // Parse the line. This is not very robust parsing, because we expect
    // a very exact format for rgb.txt. However, this is all done at comptime
    // so if our data is bad, we should hopefully get an error here or one
    // of our unit tests will catch it.
    var iter = std.mem.splitScalar(u8, data, '\n');
    var i: usize = 0;
    while (iter.next()) |raw_line| {
        // Trim \r so this works with both LF and CRLF line endings,
        // since git may convert rgb.txt to CRLF on Windows checkouts.
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;
        if (line.len == 0) continue;
        const r = try std.fmt.parseInt(u8, std.mem.trim(u8, line[0..3], " "), 10);
        const g = try std.fmt.parseInt(u8, std.mem.trim(u8, line[4..7], " "), 10);
        const b = try std.fmt.parseInt(u8, std.mem.trim(u8, line[8..11], " "), 10);
        const name = std.mem.trim(u8, line[12..], " \t");
        var name_z: [name.len:0]u8 = undefined;
        @memcpy(name_z[0..name.len], name);
        name_z[name.len] = 0;
        const final_name = name_z;
        result[i] = .{
            .name = final_name[0..name.len :0],
            .color = .{ .r = r, .g = g, .b = b },
        };
        i += 1;
    }
    assert(i == len);

    const final = result;
    return &final;
}

fn colorMap() ColorMap {
    @setEvalBranchQuota(1_000_000);

    const KV = struct { []const u8, RGB };
    var kvs: [entries.len]KV = undefined;
    for (entries, 0..) |entry, i| kvs[i] = .{ entry.name, entry.color };

    return .initComptime(kvs);
}

/// This is the rgb.txt file from the X11 project. This was last sourced
/// from this location: https://gitlab.freedesktop.org/xorg/app/rgb
/// This data is licensed under the MIT/X11 license while this Zig file is
/// licensed under the same license as Ghostty.
const data = @embedFile("res/rgb.txt");

test {
    const testing = std.testing;
    try testing.expectEqual(null, map.get("nosuchcolor"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, map.get("white").?);
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, map.get("medium spring green"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("ForestGreen"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("FoReStGReen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 0 }, map.get("black"));
    try testing.expectEqual(RGB{ .r = 255, .g = 0, .b = 0 }, map.get("red"));
    try testing.expectEqual(RGB{ .r = 0, .g = 255, .b = 0 }, map.get("green"));
    try testing.expectEqual(RGB{ .r = 0, .g = 0, .b = 255 }, map.get("blue"));
    try testing.expectEqual(RGB{ .r = 255, .g = 255, .b = 255 }, map.get("white"));
    try testing.expectEqual(RGB{ .r = 124, .g = 252, .b = 0 }, map.get("lawngreen"));
    try testing.expectEqual(RGB{ .r = 0, .g = 250, .b = 154 }, map.get("mediumspringgreen"));
    try testing.expectEqual(RGB{ .r = 34, .g = 139, .b = 34 }, map.get("forestgreen"));
}

test "entries" {
    const testing = std.testing;

    try testing.expect(entries.len > 700);
    for (entries) |entry| {
        try testing.expectEqual(entry.color, map.get(entry.name).?);
        try testing.expectEqual(@as(u8, 0), entry.name.ptr[entry.name.len]);
    }
    try testing.expectEqualStrings("snow", entries[0].name);
}
