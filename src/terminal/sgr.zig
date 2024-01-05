//! SGR (Select Graphic Rendition) attrinvbute parsing and types.

const std = @import("std");
const testing = std.testing;
const color = @import("color.zig");
const MAX_PARAMS = @import("Parser.zig").MAX_PARAMS;

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
    reset_bold: void,

    /// Italic text.
    italic: void,
    reset_italic: void,

    /// Faint/dim text.
    /// Note: reset faint is the same SGR code as reset bold
    faint: void,

    /// Underline the text
    underline: Underline,
    reset_underline: void,
    underline_color: color.RGB,
    @"256_underline_color": u8,
    reset_underline_color: void,

    /// Blink the text
    blink: void,
    reset_blink: void,

    /// Invert fg/bg colors.
    inverse: void,
    reset_inverse: void,

    /// Invisible
    invisible: void,
    reset_invisible: void,

    /// Strikethrough the text.
    strikethrough: void,
    reset_strikethrough: void,

    /// Set foreground color as RGB values.
    direct_color_fg: color.RGB,

    /// Set background color as RGB values.
    direct_color_bg: color.RGB,

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

    pub const Underline = enum(u3) {
        none = 0,
        single = 1,
        double = 2,
        curly = 3,
        dotted = 4,
        dashed = 5,
    };
};

/// Parser parses the attributes from a list of SGR parameters.
pub const Parser = struct {
    params: []const u16,
    subs: std.StaticBitSet(MAX_PARAMS) = .{ .mask = 0 },
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

            3 => return Attribute{ .italic = {} },

            4 => {
                // If we are the last attribute, no need to go further. It's a
                // single underline. The slice will always be at least 1 in
                // length but we guard against a '0' case anyways
                if (slice.len <= 1) return Attribute{ .underline = .single };

                // Check if our next param is a subparam, return early if it's
                // not
                if (!self.subs.isSet(self.idx)) return Attribute{ .underline = .single };

                // The next param is a subparam. Consume it and set
                // our underline style
                self.idx += 1;
                switch (slice[1]) {
                    0 => return Attribute{ .reset_underline = {} },
                    1 => return Attribute{ .underline = .single },
                    2 => return Attribute{ .underline = .double },
                    3 => return Attribute{ .underline = .curly },
                    4 => return Attribute{ .underline = .dotted },
                    5 => return Attribute{ .underline = .dashed },

                    // For unknown underline styles, just render
                    // a single underline.
                    else => return Attribute{ .underline = .single },
                }
            },

            5 => return Attribute{ .blink = {} },

            6 => return Attribute{ .blink = {} },

            7 => return Attribute{ .inverse = {} },

            8 => return Attribute{ .invisible = {} },

            9 => return Attribute{ .strikethrough = {} },

            22 => return Attribute{ .reset_bold = {} },

            23 => return Attribute{ .reset_italic = {} },

            24 => return Attribute{ .reset_underline = {} },

            25 => return Attribute{ .reset_blink = {} },

            27 => return Attribute{ .reset_inverse = {} },

            28 => return Attribute{ .reset_invisible = {} },

            29 => return Attribute{ .reset_strikethrough = {} },

            30...37 => return Attribute{
                .@"8_fg" = @enumFromInt(slice[0] - 30),
            },

            38 => if (slice.len >= 5 and slice[1] == 2) {
                self.idx += 4;

                // In the 6-len form, ignore the 3rd param.
                const rgb = slice[2..5];

                // We use @truncate because the value should be 0 to 255. If
                // it isn't, the behavior is undefined so we just... truncate it.
                return Attribute{
                    .direct_color_fg = .{
                        .r = @truncate(rgb[0]),
                        .g = @truncate(rgb[1]),
                        .b = @truncate(rgb[2]),
                    },
                };
            } else if (slice.len >= 3 and slice[1] == 5) {
                self.idx += 2;
                return Attribute{
                    .@"256_fg" = @truncate(slice[2]),
                };
            },

            39 => return Attribute{ .reset_fg = {} },

            40...47 => return Attribute{
                .@"8_bg" = @enumFromInt(slice[0] - 40),
            },

            48 => if (slice.len >= 5 and slice[1] == 2) {
                self.idx += 4;

                // We only support the 5-len form.
                const rgb = slice[2..5];

                // We use @truncate because the value should be 0 to 255. If
                // it isn't, the behavior is undefined so we just... truncate it.
                return Attribute{
                    .direct_color_bg = .{
                        .r = @truncate(rgb[0]),
                        .g = @truncate(rgb[1]),
                        .b = @truncate(rgb[2]),
                    },
                };
            } else if (slice.len >= 3 and slice[1] == 5) {
                self.idx += 2;
                return Attribute{
                    .@"256_bg" = @truncate(slice[2]),
                };
            },

            49 => return Attribute{ .reset_bg = {} },

            58 => if (slice.len >= 5 and slice[1] == 2) {
                self.idx += 4;

                // In the 6-len form, ignore the 3rd param. Otherwise, use it.
                const rgb = if (slice.len == 5) slice[2..5] else rgb: {
                    // Consume one more element
                    self.idx += 1;
                    break :rgb slice[3..6];
                };

                // We use @truncate because the value should be 0 to 255. If
                // it isn't, the behavior is undefined so we just... truncate it.
                return Attribute{
                    .underline_color = .{
                        .r = @truncate(rgb[0]),
                        .g = @truncate(rgb[1]),
                        .b = @truncate(rgb[2]),
                    },
                };
            } else if (slice.len >= 3 and slice[1] == 5) {
                self.idx += 2;
                return Attribute{
                    .@"256_underline_color" = @truncate(slice[2]),
                };
            },

            59 => return Attribute{ .reset_underline_color = {} },

            90...97 => return Attribute{
                // 82 instead of 90 to offset to "bright" colors
                .@"8_bright_fg" = @enumFromInt(slice[0] - 82),
            },

            100...107 => return Attribute{
                .@"8_bright_bg" = @enumFromInt(slice[0] - 92),
            },

            else => {},
        }

        return Attribute{ .unknown = .{ .full = self.params, .partial = slice } };
    }
};

fn testParse(params: []const u16, subs: []const bool) Attribute {
    std.debug.assert(params.len == subs.len);
    var bits = std.StaticBitSet(MAX_PARAMS).initEmpty();
    for (subs, 0..) |v, i| {
        bits.setValue(i, v);
    }
    var p: Parser = .{ .params = params, .subs = bits };
    return p.next().?;
}

test "sgr: Parser" {
    try testing.expect(testParse(&[_]u16{}, &[_]bool{}) == .unset);
    try testing.expect(testParse(&[_]u16{0}, &[_]bool{false}) == .unset);

    {
        const v = testParse(
            &[_]u16{ 38, 2, 40, 44, 52 },
            &[_]bool{ false, true, true, true, true },
        );
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 40), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 44), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 52), v.direct_color_fg.b);
    }

    try testing.expect(testParse(
        &[_]u16{ 38, 2, 44, 52 },
        &[_]bool{ false, true, true, true },
    ) == .unknown);

    {
        const v = testParse(
            &[_]u16{ 48, 2, 40, 44, 52 },
            &[_]bool{ false, true, true, true, true },
        );
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 40), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 44), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 52), v.direct_color_bg.b);
    }

    try testing.expect(testParse(
        &[_]u16{ 48, 2, 44, 52 },
        &[_]bool{ false, true, true, true },
    ) == .unknown);
}

test "sgr: Parser multiple" {
    var p: Parser = .{
        .params = &[_]u16{ 0, 38, 2, 40, 44, 52 },
    };
    p.subs.setRangeValue(.{ .start = 2, .end = p.params.len }, true);
    try testing.expect(p.next().? == .unset);
    try testing.expect(p.next().? == .direct_color_fg);
    try testing.expect(p.next() == null);
    try testing.expect(p.next() == null);
}

test "sgr: Parser multiple with mixed delimiters" {
    var p: Parser = .{
        .params = &[_]u16{ 4, 2, 1 },
    };
    p.subs.set(1);
    {
        const v = testParse(&[_]u16{ 4, 2 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .double);
    }
    const v = p.next().?;
    try testing.expect(v == .underline);
    try testing.expect(v.underline == .double);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: bold" {
    {
        const v = testParse(&[_]u16{1}, &[_]bool{false});
        try testing.expect(v == .bold);
    }

    {
        const v = testParse(&[_]u16{22}, &[_]bool{false});
        try testing.expect(v == .reset_bold);
    }
}

test "sgr: italic" {
    {
        const v = testParse(&[_]u16{3}, &[_]bool{false});
        try testing.expect(v == .italic);
    }

    {
        const v = testParse(&[_]u16{23}, &[_]bool{false});
        try testing.expect(v == .reset_italic);
    }
}

test "sgr: underline" {
    {
        const v = testParse(&[_]u16{4}, &[_]bool{false});
        try testing.expect(v == .underline);
    }

    {
        const v = testParse(&[_]u16{24}, &[_]bool{false});
        try testing.expect(v == .reset_underline);
    }
}

test "sgr: underline styles" {
    {
        const v = testParse(&[_]u16{ 4, 2 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .double);
    }

    {
        const v = testParse(&[_]u16{ 4, 0 }, &[_]bool{ false, true });
        try testing.expect(v == .reset_underline);
    }

    {
        const v = testParse(&[_]u16{ 4, 1 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .single);
    }

    {
        const v = testParse(&[_]u16{ 4, 3 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .curly);
    }

    {
        const v = testParse(&[_]u16{ 4, 4 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .dotted);
    }

    {
        const v = testParse(&[_]u16{ 4, 5 }, &[_]bool{ false, true });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .dashed);
    }
}

test "sgr: blink" {
    {
        const v = testParse(&[_]u16{5}, &[_]bool{false});
        try testing.expect(v == .blink);
    }

    {
        const v = testParse(&[_]u16{6}, &[_]bool{false});
        try testing.expect(v == .blink);
    }

    {
        const v = testParse(&[_]u16{25}, &[_]bool{false});
        try testing.expect(v == .reset_blink);
    }
}

test "sgr: inverse" {
    {
        const v = testParse(&[_]u16{7}, &[_]bool{false});
        try testing.expect(v == .inverse);
    }

    {
        const v = testParse(&[_]u16{27}, &[_]bool{false});
        try testing.expect(v == .reset_inverse);
    }
}

test "sgr: strikethrough" {
    {
        const v = testParse(&[_]u16{9}, &[_]bool{false});
        try testing.expect(v == .strikethrough);
    }

    {
        const v = testParse(&[_]u16{29}, &[_]bool{false});
        try testing.expect(v == .reset_strikethrough);
    }
}

test "sgr: 8 color" {
    var p: Parser = .{
        .params = &[_]u16{ 31, 43, 90, 103 },
    };

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
    var p: Parser = .{
        .params = &[_]u16{ 38, 5, 161, 48, 5, 236 },
    };
    p.subs.set(1);
    p.subs.set(2);
    p.subs.set(4);
    p.subs.set(5);
    try testing.expect(p.next().? == .@"256_fg");
    try testing.expect(p.next().? == .@"256_bg");
    try testing.expect(p.next() == null);
}

test "sgr: 256 color underline" {
    var p: Parser = .{
        .params = &[_]u16{ 58, 5, 9 },
    };
    p.subs.set(1);
    p.subs.set(2);
    try testing.expect(p.next().? == .@"256_underline_color");
    try testing.expect(p.next() == null);
}

test "sgr: 24-bit bg color" {
    {
        const v = testParse(
            &[_]u16{ 48, 2, 1, 2, 3 },
            &[_]bool{ false, true, true, true, true },
        );
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_bg.b);
    }
}

test "sgr: underline color" {
    {
        const v = testParse(
            &[_]u16{ 58, 2, 1, 2, 3 },
            &[_]bool{ false, true, true, true, true },
        );
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 1), v.underline_color.r);
        try testing.expectEqual(@as(u8, 2), v.underline_color.g);
        try testing.expectEqual(@as(u8, 3), v.underline_color.b);
    }

    {
        const v = testParse(
            &[_]u16{ 58, 2, 0, 1, 2, 3 },
            &[_]bool{ false, true, true, true, true, true },
        );
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 1), v.underline_color.r);
        try testing.expectEqual(@as(u8, 2), v.underline_color.g);
        try testing.expectEqual(@as(u8, 3), v.underline_color.b);
    }
}

test "sgr: reset underline color" {
    var p: Parser = .{
        .params = &[_]u16{59},
    };
    try testing.expect(p.next().? == .reset_underline_color);
}

test "sgr: invisible" {
    var p: Parser = .{
        .params = &[_]u16{ 8, 28 },
    };
    try testing.expect(p.next().? == .invisible);
    try testing.expect(p.next().? == .reset_invisible);
}

test "sgr: underline, bg, and fg" {
    var p: Parser = .{
        .params = &[_]u16{ 4, 38, 2, 255, 247, 219, 48, 2, 242, 93, 147, 4 },
    };
    p.subs.setRangeValue(.{ .start = 2, .end = 6 }, true);
    p.subs.setRangeValue(.{ .start = 7, .end = 11 }, true);
    {
        const v = p.next().?;
        try testing.expect(v == .underline);
        try testing.expectEqual(Attribute.Underline.single, v.underline);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 255), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 247), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 219), v.direct_color_fg.b);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 242), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 93), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 147), v.direct_color_bg.b);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .underline);
        try testing.expectEqual(Attribute.Underline.single, v.underline);
    }
}

test "sgr: direct color fg missing color" {
    // This used to crash
    var p: Parser = .{
        .params = &[_]u16{ 38, 5 },
    };
    p.subs.set(1);
    while (p.next()) |_| {}
}

test "sgr: direct color bg missing color" {
    // This used to crash
    var p: Parser = .{
        .params = &[_]u16{ 48, 5 },
    };
    p.subs.set(1);
    while (p.next()) |_| {}
}
