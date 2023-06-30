const std = @import("std");
const assert = std.debug.assert;

/// The default palette.
pub const default: Palette = default: {
    var result: Palette = undefined;

    // Named values
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        result[i] = Name.default(@enumFromInt(i)) catch unreachable;
    }

    // Cube
    assert(i == 16);
    var r: u8 = 0;
    while (r < 6) : (r += 1) {
        var g: u8 = 0;
        while (g < 6) : (g += 1) {
            var b: u8 = 0;
            while (b < 6) : (b += 1) {
                result[i] = .{
                    .r = if (r == 0) 0 else (r * 40 + 55),
                    .g = if (g == 0) 0 else (g * 40 + 55),
                    .b = if (b == 0) 0 else (b * 40 + 55),
                };

                i += 1;
            }
        }
    }

    // Grey ramp
    assert(i == 232);
    assert(@TypeOf(i) == u8);
    while (i > 0) : (i +%= 1) {
        const value = ((i - 232) * 10) + 8;
        result[i] = .{ .r = value, .g = value, .b = value };
    }

    break :default result;
};

/// Palette is the 256 color palette.
pub const Palette = [256]RGB;

/// Color names in the standard 8 or 16 color palette.
pub const Name = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,

    // Remainders are valid unnamed values in the 256 color palette.
    _,

    /// Default colors for tagged values.
    pub fn default(self: Name) !RGB {
        return switch (self) {
            .black => RGB{ .r = 0x1D, .g = 0x1F, .b = 0x21 },
            .red => RGB{ .r = 0xCC, .g = 0x66, .b = 0x66 },
            .green => RGB{ .r = 0xB5, .g = 0xBD, .b = 0x68 },
            .yellow => RGB{ .r = 0xF0, .g = 0xC6, .b = 0x74 },
            .blue => RGB{ .r = 0x81, .g = 0xA2, .b = 0xBE },
            .magenta => RGB{ .r = 0xB2, .g = 0x94, .b = 0xBB },
            .cyan => RGB{ .r = 0x8A, .g = 0xBE, .b = 0xB7 },
            .white => RGB{ .r = 0xC5, .g = 0xC8, .b = 0xC6 },

            .bright_black => RGB{ .r = 0x66, .g = 0x66, .b = 0x66 },
            .bright_red => RGB{ .r = 0xD5, .g = 0x4E, .b = 0x53 },
            .bright_green => RGB{ .r = 0xB9, .g = 0xCA, .b = 0x4A },
            .bright_yellow => RGB{ .r = 0xE7, .g = 0xC5, .b = 0x47 },
            .bright_blue => RGB{ .r = 0x7A, .g = 0xA6, .b = 0xDA },
            .bright_magenta => RGB{ .r = 0xC3, .g = 0x97, .b = 0xD8 },
            .bright_cyan => RGB{ .r = 0x70, .g = 0xC0, .b = 0xB1 },
            .bright_white => RGB{ .r = 0xEA, .g = 0xEA, .b = 0xEA },

            else => error.NoDefaultValue,
        };
    }
};

/// RGB
pub const RGB = struct {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,

    test "size" {
        try std.testing.expectEqual(@as(usize, 24), @bitSizeOf(RGB));
        try std.testing.expectEqual(@as(usize, 3), @sizeOf(RGB));
    }
};

test "palette: default" {
    const testing = std.testing;

    // Safety check
    var i: u8 = 0;
    while (i < 16) : (i += 1) {
        try testing.expectEqual(Name.default(@as(Name, @enumFromInt(i))), default[i]);
    }
}
