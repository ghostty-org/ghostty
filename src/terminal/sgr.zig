//! SGR (Select Graphic Rendition) attribute parsing and types.

const std = @import("std");
const testing = std.testing;
const color = @import("color.zig");

/// Attribute type for SGR
pub const Attribute = union(enum) {
    /// Unset all attributes
    unset: void,

    /// Unknown attribute, the raw CSI command parameters are here.
    unknown: struct {
        /// Full is the full SGR input.
        full: []const u16,

        /// Partial is the remaining, where we got hung up.
        partial: []const u16,
    },

    /// Bold the text.
    bold: void,

    /// Faint/dim text.
    faint: void,

    /// Underline the text
    underline: void,

    /// Blink the text
    blink: void,

    /// Invert fg/bg colors.
    inverse: void,
    reset_inverse: void,

    /// Strikethrough the text.
    strikethrough: void,
    reset_strikethrough: void,

    /// Set foreground color as RGB values.
    direct_color_fg: RGB,

    /// Set background color as RGB values.
    direct_color_bg: RGB,

    /// Set the background/foreground as a named color attribute.
    @"8_bg": color.Name,
    @"8_fg": color.Name,

    /// Reset the fg/bg to their default values.
    reset_fg: void,
    reset_bg: void,

    /// Set the background/foreground as a named bright color attribute.
    @"8_bright_bg": color.Name,
    @"8_bright_fg": color.Name,

    /// Set background color as 256-color palette.
    @"256_bg": u8,

    /// Set foreground color as 256-color palette.
    @"256_fg": u8,

    pub const RGB = struct {
        r: u8,
        g: u8,
        b: u8,
    };
};

/// Parser parses the attributes from a list of SGR parameters.
pub const Parser = struct {
    params: []const u16,
    idx: usize = 0,

    /// Next returns the next attribute or null if there are no more attributes.
    pub fn next(self: *Parser) ?Attribute {
        if (self.idx > self.params.len) return null;

        // Implicitly means unset
        if (self.params.len == 0) {
            self.idx += 1;
            return Attribute{ .unset = {} };
        }

        const slice = self.params[self.idx..self.params.len];
        self.idx += 1;

        // Our last one will have an idx be the last value.
        if (slice.len == 0) return null;

        switch (slice[0]) {
            0 => return Attribute{ .unset = {} },

            1 => return Attribute{ .bold = {} },

            2 => return Attribute{ .faint = {} },

            4 => return Attribute{ .underline = {} },

            5 => return Attribute{ .blink = {} },

            7 => return Attribute{ .inverse = {} },

            9 => return Attribute{ .strikethrough = {} },

            27 => return Attribute{ .reset_inverse = {} },

            29 => return Attribute{ .reset_strikethrough = {} },

            30...37 => return Attribute{
                .@"8_fg" = @intToEnum(color.Name, slice[0] - 30),
            },

            38 => if (slice.len >= 5 and slice[1] == 2) {
                self.idx += 4;

                // In the 6-len form, ignore the 3rd param.
                const rgb = slice[2..5];

                // We use @truncate because the value should be 0 to 255. If
                // it isn't, the behavior is undefined so we just... truncate it.
                return Attribute{
                    .direct_color_fg = .{
                        .r = @truncate(u8, rgb[0]),
                        .g = @truncate(u8, rgb[1]),
                        .b = @truncate(u8, rgb[2]),
                    },
                };
            } else if (slice.len >= 2 and slice[1] == 5) {
                self.idx += 2;
                return Attribute{
                    .@"256_fg" = @truncate(u8, slice[2]),
                };
            },

            39 => return Attribute{ .reset_fg = {} },

            40...47 => return Attribute{
                .@"8_bg" = @intToEnum(color.Name, slice[0] - 40),
            },

            48 => if (slice.len >= 5 and slice[1] == 2) {
                self.idx += 4;

                // In the 6-len form, ignore the 3rd param.
                const rgb = slice[2..5];

                // We use @truncate because the value should be 0 to 255. If
                // it isn't, the behavior is undefined so we just... truncate it.
                return Attribute{
                    .direct_color_bg = .{
                        .r = @truncate(u8, rgb[0]),
                        .g = @truncate(u8, rgb[1]),
                        .b = @truncate(u8, rgb[2]),
                    },
                };
            } else if (slice.len >= 2 and slice[1] == 5) {
                self.idx += 2;
                return Attribute{
                    .@"256_bg" = @truncate(u8, slice[2]),
                };
            },

            49 => return Attribute{ .reset_bg = {} },

            90...97 => return Attribute{
                // 82 instead of 90 to offset to "bright" colors
                .@"8_bright_fg" = @intToEnum(color.Name, slice[0] - 82),
            },

            100...107 => return Attribute{
                .@"8_bright_bg" = @intToEnum(color.Name, slice[0] - 92),
            },

            else => {},
        }

        return Attribute{ .unknown = .{ .full = self.params, .partial = slice } };
    }
};

fn testParse(params: []const u16) Attribute {
    var p: Parser = .{ .params = params };
    return p.next().?;
}

test "sgr: Parser" {
    try testing.expect(testParse(&[_]u16{}) == .unset);
    try testing.expect(testParse(&[_]u16{0}) == .unset);

    {
        const v = testParse(&[_]u16{ 38, 2, 40, 44, 52 });
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 40), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 44), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 52), v.direct_color_fg.b);
    }

    try testing.expect(testParse(&[_]u16{ 38, 2, 44, 52 }) == .unknown);

    {
        const v = testParse(&[_]u16{ 48, 2, 40, 44, 52 });
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 40), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 44), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 52), v.direct_color_bg.b);
    }

    try testing.expect(testParse(&[_]u16{ 48, 2, 44, 52 }) == .unknown);
}

test "sgr: Parser multiple" {
    var p: Parser = .{ .params = &[_]u16{ 0, 38, 2, 40, 44, 52 } };
    try testing.expect(p.next().? == .unset);
    try testing.expect(p.next().? == .direct_color_fg);
    try testing.expect(p.next() == null);
    try testing.expect(p.next() == null);
}

test "sgr: bold" {
    const v = testParse(&[_]u16{1});
    try testing.expect(v == .bold);
}

test "sgr: inverse" {
    {
        const v = testParse(&[_]u16{7});
        try testing.expect(v == .inverse);
    }

    {
        const v = testParse(&[_]u16{27});
        try testing.expect(v == .reset_inverse);
    }
}

test "sgr: strikethrough" {
    {
        const v = testParse(&[_]u16{9});
        try testing.expect(v == .strikethrough);
    }

    {
        const v = testParse(&[_]u16{29});
        try testing.expect(v == .reset_strikethrough);
    }
}

test "sgr: 8 color" {
    var p: Parser = .{ .params = &[_]u16{ 31, 43, 90, 103 } };

    {
        const v = p.next().?;
        try testing.expect(v == .@"8_fg");
        try testing.expect(v.@"8_fg" == .red);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .@"8_bg");
        try testing.expect(v.@"8_bg" == .yellow);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .@"8_bright_fg");
        try testing.expect(v.@"8_bright_fg" == .bright_black);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .@"8_bright_bg");
        try testing.expect(v.@"8_bright_bg" == .bright_yellow);
    }
}

test "sgr: 256 color" {
    var p: Parser = .{ .params = &[_]u16{ 38, 5, 161, 48, 5, 236 } };
    try testing.expect(p.next().? == .@"256_fg");
    try testing.expect(p.next().? == .@"256_bg");
}
