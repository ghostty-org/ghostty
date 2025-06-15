//! SGR (Select Graphic Rendition) attrinvbute parsing and types.

const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const color = @import("color.zig");
const SepList = @import("Parser.zig").Action.CSI.SepList;

/// Attribute type for SGR
pub const Attribute = union(enum) {
    pub const Tag = std.meta.FieldEnum(Attribute);

    /// Unset all attributes
    unset,

    /// Unknown attribute, the raw CSI command parameters are here.
    unknown: struct {
        /// Full is the full SGR input.
        full: []const u16,

        /// Partial is the remaining, where we got hung up.
        partial: []const u16,
    },

    /// Bold the text.
    bold,
    reset_bold,

    /// Italic text.
    italic,
    reset_italic,

    /// Faint/dim text.
    /// Note: reset faint is the same SGR code as reset bold
    faint,

    /// Underline the text
    underline: Underline,
    reset_underline,
    underline_color: color.RGB,
    @"256_underline_color": u8,
    reset_underline_color,

    // Overline the text
    overline,
    reset_overline,

    /// Blink the text
    blink,
    reset_blink,

    /// Invert fg/bg colors.
    inverse,
    reset_inverse,

    /// Invisible
    invisible,
    reset_invisible,

    /// Strikethrough the text.
    strikethrough,
    reset_strikethrough,

    /// Set foreground color as RGB values.
    direct_color_fg: color.RGB,

    /// Set background color as RGB values.
    direct_color_bg: color.RGB,

    /// Set the background/foreground as a named color attribute.
    @"8_bg": color.Name,
    @"8_fg": color.Name,

    /// Reset the fg/bg to their default values.
    reset_fg,
    reset_bg,

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
    params_sep: SepList = .initEmpty(),
    idx: usize = 0,

    /// Next returns the next attribute or null if there are no more attributes.
    pub fn next(self: *Parser) ?Attribute {
        if (self.idx >= self.params.len) {
            // If we're at index zero it means we must have an empty
            // list and an empty list implicitly means unset.
            if (self.idx == 0) {
                // Add one to ensure we don't loop on unset
                self.idx += 1;
                return .unset;
            }

            return null;
        }

        const slice = self.params[self.idx..self.params.len];
        const colon = self.params_sep.isSet(self.idx);
        self.idx += 1;

        // Our last one will have an idx be the last value.
        if (slice.len == 0) return null;

        // If we have a colon separator then we need to ensure we're
        // parsing a value that allows it.
        if (colon) switch (slice[0]) {
            4, 38, 48, 58 => {},

            else => {
                // Consume all the colon separated values.
                const start = self.idx;
                while (self.params_sep.isSet(self.idx)) self.idx += 1;
                self.idx += 1;
                return .{ .unknown = .{
                    .full = self.params,
                    .partial = slice[0 .. self.idx - start + 1],
                } };
            },
        };

        switch (slice[0]) {
            0 => return .unset,

            1 => return .bold,

            2 => return .faint,

            3 => return .italic,

            4 => underline: {
                if (colon) {
                    assert(slice.len >= 2);
                    if (self.isColon()) {
                        self.consumeUnknownColon();
                        break :underline;
                    }

                    self.idx += 1;
                    switch (slice[1]) {
                        0 => return .reset_underline,
                        1 => return .{ .underline = .single },
                        2 => return .{ .underline = .double },
                        3 => return .{ .underline = .curly },
                        4 => return .{ .underline = .dotted },
                        5 => return .{ .underline = .dashed },

                        // For unknown underline styles, just render
                        // a single underline.
                        else => return .{ .underline = .single },
                    }
                }

                return .{ .underline = .single };
            },

            5 => return .blink,

            6 => return .blink,

            7 => return .inverse,

            8 => return .invisible,

            9 => return .strikethrough,

            21 => return .{ .underline = .double },

            22 => return .reset_bold,

            23 => return .reset_italic,

            24 => return .reset_underline,

            25 => return .reset_blink,

            27 => return .reset_inverse,

            28 => return .reset_invisible,

            29 => return .reset_strikethrough,

            30...37 => return .{
                .@"8_fg" = @enumFromInt(slice[0] - 30),
            },

            38 => if (slice.len >= 2) switch (slice[1]) {
                // `2` indicates direct-color (r, g, b).
                // We need at least 3 more params for this to make sense.
                2 => if (self.parseDirectColor(
                    .direct_color_fg,
                    slice,
                    colon,
                )) |v| return v,

                // `5` indicates indexed color.
                5 => if (slice.len >= 3) {
                    self.idx += 2;
                    return .{
                        .@"256_fg" = @truncate(slice[2]),
                    };
                },
                else => {},
            },

            39 => return .reset_fg,

            40...47 => return .{
                .@"8_bg" = @enumFromInt(slice[0] - 40),
            },

            48 => if (slice.len >= 2) switch (slice[1]) {
                // `2` indicates direct-color (r, g, b).
                // We need at least 3 more params for this to make sense.
                2 => if (self.parseDirectColor(
                    .direct_color_bg,
                    slice,
                    colon,
                )) |v| return v,

                // `5` indicates indexed color.
                5 => if (slice.len >= 3) {
                    self.idx += 2;
                    return .{
                        .@"256_bg" = @truncate(slice[2]),
                    };
                },
                else => {},
            },

            49 => return .reset_bg,

            53 => return .overline,
            55 => return .reset_overline,

            58 => if (slice.len >= 2) switch (slice[1]) {
                // `2` indicates direct-color (r, g, b).
                // We need at least 3 more params for this to make sense.
                2 => if (self.parseDirectColor(
                    .underline_color,
                    slice,
                    colon,
                )) |v| return v,

                // `5` indicates indexed color.
                5 => if (slice.len >= 3) {
                    self.idx += 2;
                    return .{
                        .@"256_underline_color" = @truncate(slice[2]),
                    };
                },
                else => {},
            },

            59 => return .reset_underline_color,

            90...97 => return .{
                // 82 instead of 90 to offset to "bright" colors
                .@"8_bright_fg" = @enumFromInt(slice[0] - 82),
            },

            100...107 => return .{
                .@"8_bright_bg" = @enumFromInt(slice[0] - 92),
            },

            else => {},
        }

        return .{ .unknown = .{ .full = self.params, .partial = slice } };
    }

    fn parseDirectColor(
        self: *Parser,
        comptime tag: Attribute.Tag,
        slice: []const u16,
        colon: bool,
    ) ?Attribute {
        // Any direct color style must have at least 5 values.
        if (slice.len < 5) return null;

        // Only used for direct color sets (38, 48, 58) and subparam 2.
        assert(slice[1] == 2);

        // Note: We use @truncate because the value should be 0 to 255. If
        // it isn't, the behavior is undefined so we just... truncate it.

        // If we don't have a colon, then we expect exactly 3 semicolon
        // separated values.
        if (!colon) {
            self.idx += 4;
            return @unionInit(Attribute, @tagName(tag), .{
                .r = @truncate(slice[2]),
                .g = @truncate(slice[3]),
                .b = @truncate(slice[4]),
            });
        }

        // We have a colon, we might have either 5 or 6 values depending
        // on if the colorspace is present.
        const count = self.countColon();
        switch (count) {
            3 => {
                self.idx += 4;
                return @unionInit(Attribute, @tagName(tag), .{
                    .r = @truncate(slice[2]),
                    .g = @truncate(slice[3]),
                    .b = @truncate(slice[4]),
                });
            },

            4 => {
                self.idx += 5;
                return @unionInit(Attribute, @tagName(tag), .{
                    .r = @truncate(slice[3]),
                    .g = @truncate(slice[4]),
                    .b = @truncate(slice[5]),
                });
            },

            else => {
                self.consumeUnknownColon();
                return null;
            },
        }
    }

    /// Returns true if the present position has a colon separator.
    /// This always returns false for the last value since it has no
    /// separator.
    fn isColon(self: *Parser) bool {
        // The `- 1` here is because the last value has no separator.
        if (self.idx >= self.params.len - 1) return false;
        return self.params_sep.isSet(self.idx);
    }

    fn countColon(self: *Parser) usize {
        var count: usize = 0;
        var idx = self.idx;
        while (idx < self.params.len - 1 and self.params_sep.isSet(idx)) : (idx += 1) {
            count += 1;
        }
        return count;
    }

    /// Consumes all the remaining parameters separated by a colon and
    /// returns an unknown attribute.
    fn consumeUnknownColon(self: *Parser) void {
        const count = self.countColon();
        self.idx += count + 1;
    }
};

fn testParse(params: []const u16) Attribute {
    var p: Parser = .{ .params = params };
    return p.next().?;
}

fn testParseColon(params: []const u16) Attribute {
    var p: Parser = .{ .params = params, .params_sep = .initFull() };
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

test "sgr: unsupported with colon" {
    var p: Parser = .{
        .params = &[_]u16{ 0, 4, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(0);
            break :sep list;
        },
    };
    try testing.expect(p.next().? == .unknown);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: unsupported with multiple colon" {
    var p: Parser = .{
        .params = &[_]u16{ 0, 4, 2, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(0);
            list.set(1);
            break :sep list;
        },
    };
    try testing.expect(p.next().? == .unknown);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: bold" {
    {
        const v = testParse(&[_]u16{1});
        try testing.expect(v == .bold);
    }

    {
        const v = testParse(&[_]u16{22});
        try testing.expect(v == .reset_bold);
    }
}

test "sgr: italic" {
    {
        const v = testParse(&[_]u16{3});
        try testing.expect(v == .italic);
    }

    {
        const v = testParse(&[_]u16{23});
        try testing.expect(v == .reset_italic);
    }
}

test "sgr: underline" {
    {
        const v = testParse(&[_]u16{4});
        try testing.expect(v == .underline);
    }

    {
        const v = testParse(&[_]u16{24});
        try testing.expect(v == .reset_underline);
    }
}

test "sgr: underline styles" {
    {
        const v = testParseColon(&[_]u16{ 4, 2 });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .double);
    }

    {
        const v = testParseColon(&[_]u16{ 4, 0 });
        try testing.expect(v == .reset_underline);
    }

    {
        const v = testParseColon(&[_]u16{ 4, 1 });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .single);
    }

    {
        const v = testParseColon(&[_]u16{ 4, 3 });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .curly);
    }

    {
        const v = testParseColon(&[_]u16{ 4, 4 });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .dotted);
    }

    {
        const v = testParseColon(&[_]u16{ 4, 5 });
        try testing.expect(v == .underline);
        try testing.expect(v.underline == .dashed);
    }
}

test "sgr: underline style with more" {
    var p: Parser = .{
        .params = &[_]u16{ 4, 2, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(0);
            break :sep list;
        },
    };

    try testing.expect(p.next().? == .underline);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: underline style with too many colons" {
    var p: Parser = .{
        .params = &[_]u16{ 4, 2, 3, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(0);
            list.set(1);
            break :sep list;
        },
    };

    try testing.expect(p.next().? == .unknown);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: blink" {
    {
        const v = testParse(&[_]u16{5});
        try testing.expect(v == .blink);
    }

    {
        const v = testParse(&[_]u16{6});
        try testing.expect(v == .blink);
    }

    {
        const v = testParse(&[_]u16{25});
        try testing.expect(v == .reset_blink);
    }
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
    try testing.expect(p.next() == null);
}

test "sgr: 256 color underline" {
    var p: Parser = .{ .params = &[_]u16{ 58, 5, 9 } };
    try testing.expect(p.next().? == .@"256_underline_color");
    try testing.expect(p.next() == null);
}

test "sgr: 24-bit bg color" {
    {
        const v = testParseColon(&[_]u16{ 48, 2, 1, 2, 3 });
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_bg.b);
    }
}

test "sgr: underline color" {
    {
        const v = testParseColon(&[_]u16{ 58, 2, 1, 2, 3 });
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 1), v.underline_color.r);
        try testing.expectEqual(@as(u8, 2), v.underline_color.g);
        try testing.expectEqual(@as(u8, 3), v.underline_color.b);
    }

    {
        const v = testParseColon(&[_]u16{ 58, 2, 0, 1, 2, 3 });
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 1), v.underline_color.r);
        try testing.expectEqual(@as(u8, 2), v.underline_color.g);
        try testing.expectEqual(@as(u8, 3), v.underline_color.b);
    }
}

test "sgr: reset underline color" {
    var p: Parser = .{ .params = &[_]u16{59} };
    try testing.expect(p.next().? == .reset_underline_color);
}

test "sgr: invisible" {
    var p: Parser = .{ .params = &[_]u16{ 8, 28 } };
    try testing.expect(p.next().? == .invisible);
    try testing.expect(p.next().? == .reset_invisible);
}

test "sgr: underline, bg, and fg" {
    var p: Parser = .{
        .params = &[_]u16{ 4, 38, 2, 255, 247, 219, 48, 2, 242, 93, 147, 4 },
    };
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
    var p: Parser = .{ .params = &[_]u16{ 38, 5 } };
    while (p.next()) |_| {}
}

test "sgr: direct color bg missing color" {
    // This used to crash
    var p: Parser = .{ .params = &[_]u16{ 48, 5 } };
    while (p.next()) |_| {}
}

test "sgr: direct fg/bg/underline ignore optional color space" {
    // These behaviors have been verified against xterm.

    // Colon version should skip the optional color space identifier
    {
        // 3 8 : 2 : Pi : Pr : Pg : Pb
        const v = testParseColon(&[_]u16{ 38, 2, 0, 1, 2, 3 });
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_fg.b);
    }
    {
        // 4 8 : 2 : Pi : Pr : Pg : Pb
        const v = testParseColon(&[_]u16{ 48, 2, 0, 1, 2, 3 });
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_bg.b);
    }
    {
        // 5 8 : 2 : Pi : Pr : Pg : Pb
        const v = testParseColon(&[_]u16{ 58, 2, 0, 1, 2, 3 });
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 1), v.underline_color.r);
        try testing.expectEqual(@as(u8, 2), v.underline_color.g);
        try testing.expectEqual(@as(u8, 3), v.underline_color.b);
    }

    // Semicolon version should not parse optional color space identifier
    {
        // 3 8 ; 2 ; Pr ; Pg ; Pb
        const v = testParse(&[_]u16{ 38, 2, 0, 1, 2, 3 });
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 0), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 1), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 2), v.direct_color_fg.b);
    }
    {
        // 4 8 ; 2 ; Pr ; Pg ; Pb
        const v = testParse(&[_]u16{ 48, 2, 0, 1, 2, 3 });
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 0), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 1), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 2), v.direct_color_bg.b);
    }
    {
        // 5 8 ; 2 ; Pr ; Pg ; Pb
        const v = testParse(&[_]u16{ 58, 2, 0, 1, 2, 3 });
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 0), v.underline_color.r);
        try testing.expectEqual(@as(u8, 1), v.underline_color.g);
        try testing.expectEqual(@as(u8, 2), v.underline_color.b);
    }
}

test "sgr: direct fg colon with too many colons" {
    var p: Parser = .{
        .params = &[_]u16{ 38, 2, 0, 1, 2, 3, 4, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            for (0..6) |idx| list.set(idx);
            break :sep list;
        },
    };

    try testing.expect(p.next().? == .unknown);
    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: direct fg colon with colorspace and extra param" {
    var p: Parser = .{
        .params = &[_]u16{ 38, 2, 0, 1, 2, 3, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            for (0..5) |idx| list.set(idx);
            break :sep list;
        },
    };

    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_fg.b);
    }

    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

test "sgr: direct fg colon no colorspace and extra param" {
    var p: Parser = .{
        .params = &[_]u16{ 38, 2, 1, 2, 3, 1 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            for (0..4) |idx| list.set(idx);
            break :sep list;
        },
    };

    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 1), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 2), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 3), v.direct_color_fg.b);
    }

    try testing.expect(p.next().? == .bold);
    try testing.expect(p.next() == null);
}

// Kakoune sent this complex SGR sequence that caused invalid behavior.
test "sgr: kakoune input" {
    // This used to crash
    var p: Parser = .{
        .params = &[_]u16{ 0, 4, 3, 38, 2, 175, 175, 215, 58, 2, 0, 190, 80, 70 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(1);
            list.set(8);
            list.set(9);
            list.set(10);
            list.set(11);
            list.set(12);
            break :sep list;
        },
    };

    {
        const v = p.next().?;
        try testing.expect(v == .unset);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .underline);
        try testing.expectEqual(Attribute.Underline.curly, v.underline);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 175), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 175), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 215), v.direct_color_fg.b);
    }
    {
        const v = p.next().?;
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 190), v.underline_color.r);
        try testing.expectEqual(@as(u8, 80), v.underline_color.g);
        try testing.expectEqual(@as(u8, 70), v.underline_color.b);
    }

    //try testing.expect(p.next() == null);
}

// Discussion #5930, another input sent by kakoune
test "sgr: kakoune input issue underline, fg, and bg" {
    // echo -e "\033[4:3;38;2;51;51;51;48;2;170;170;170;58;2;255;97;136mset everything in one sequence, broken\033[m"

    // This used to crash
    var p: Parser = .{
        .params = &[_]u16{ 4, 3, 38, 2, 51, 51, 51, 48, 2, 170, 170, 170, 58, 2, 255, 97, 136 },
        .params_sep = sep: {
            var list = SepList.initEmpty();
            list.set(0);
            break :sep list;
        },
    };

    {
        const v = p.next().?;
        try testing.expect(v == .underline);
        try testing.expectEqual(Attribute.Underline.curly, v.underline);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_fg);
        try testing.expectEqual(@as(u8, 51), v.direct_color_fg.r);
        try testing.expectEqual(@as(u8, 51), v.direct_color_fg.g);
        try testing.expectEqual(@as(u8, 51), v.direct_color_fg.b);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .direct_color_bg);
        try testing.expectEqual(@as(u8, 170), v.direct_color_bg.r);
        try testing.expectEqual(@as(u8, 170), v.direct_color_bg.g);
        try testing.expectEqual(@as(u8, 170), v.direct_color_bg.b);
    }

    {
        const v = p.next().?;
        try testing.expect(v == .underline_color);
        try testing.expectEqual(@as(u8, 255), v.underline_color.r);
        try testing.expectEqual(@as(u8, 97), v.underline_color.g);
        try testing.expectEqual(@as(u8, 136), v.underline_color.b);
    }

    try testing.expect(p.next() == null);
}
