const std = @import("std");
const assert = std.debug.assert;
const RGB = @import("color.zig").RGB;

/// The map of all available X11 colors.
pub const map = colorMap() catch @compileError("failed to parse rgb.txt");

pub const ColorMap = std.StaticStringMapWithEql(RGB, std.static_string_map.eqlAsciiIgnoreCase);

fn colorMap() !ColorMap {
    @setEvalBranchQuota(500_000);

    const KV = struct { []const u8, RGB };

    // The length of our data is the number of lines in the rgb file.
    const len = std.mem.count(u8, data, "\n");
    var kvs: [len]KV = undefined;

    // Parse the line. This is not very robust parsing, because we expect
    // a very exact format for rgb.txt. However, this is all done at comptime
    // so if our data is bad, we should hopefully get an error here or one
    // of our unit tests will catch it.
    var iter = std.mem.splitScalar(u8, data, '\n');
    var i: usize = 0;
    while (iter.next()) |line| {
        if (line.len == 0) continue;
        const r = try std.fmt.parseInt(u8, std.mem.trim(u8, line[0..3], " "), 10);
        const g = try std.fmt.parseInt(u8, std.mem.trim(u8, line[4..7], " "), 10);
        const b = try std.fmt.parseInt(u8, std.mem.trim(u8, line[8..11], " "), 10);
        const name = std.mem.trim(u8, line[12..], " \t\n");
        kvs[i] = .{ name, .{ .r = r, .g = g, .b = b } };
        i += 1;
    }
    assert(i == len);

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
