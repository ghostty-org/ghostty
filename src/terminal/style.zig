const std = @import("std");
const assert = std.debug.assert;
const configpkg = @import("../config.zig");
const color = @import("color.zig");
const sgr = @import("sgr.zig");
const page = @import("page.zig");
const size = @import("size.zig");
const Offset = size.Offset;
const OffsetBuf = size.OffsetBuf;
const RefCountedSet = @import("ref_counted_set.zig").RefCountedSet;

/// The unique identifier for a style. This is at most the number of cells
/// that can fit into a terminal page.
pub const Id = size.CellCountInt;

/// The Id to use for default styling.
pub const default_id: Id = 0;

/// The style attributes for a cell.
pub const Style = struct {
    /// Various colors, all self-explanatory.
    fg_color: Color = .none,
    bg_color: Color = .none,
    underline_color: Color = .none,

    /// On/off attributes that don't require much bit width so we use
    /// a packed struct to make this take up significantly less space.
    flags: Flags = .{},

    const Flags = packed struct(u16) {
        bold: bool = false,
        italic: bool = false,
        faint: bool = false,
        blink: bool = false,
        inverse: bool = false,
        invisible: bool = false,
        strikethrough: bool = false,
        overline: bool = false,
        underline: sgr.Attribute.Underline = .none,
        _padding: u5 = 0,
    };

    /// The color for an SGR attribute. A color can come from multiple
    /// sources so we use this to track the source plus color value so that
    /// we can properly react to things like palette changes.
    pub const Color = union(Tag) {
        none: void,
        palette: u8,
        rgb: color.RGB,

        const Tag = enum(u8) {
            none,
            palette,
            rgb,
        };

        /// Formatting to make debug logs easier to read
        /// by only including non-default attributes.
        pub fn format(
            self: Color,
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: *std.Io.Writer,
        ) !void {
            _ = fmt;
            _ = options;
            switch (self) {
                .none => {
                    _ = try writer.write("Color.none");
                },
                .palette => |p| {
                    _ = try writer.print("Color.palette{{ {} }}", .{p});
                },
                .rgb => |rgb| {
                    _ = try writer.print("Color.rgb{{ {}, {}, {} }}", .{ rgb.r, rgb.g, rgb.b });
                },
            }
        }
    };

    /// True if the style is the default style.
    pub fn default(self: Style) bool {
        return self.eql(.{});
    }

    /// True if the style is equal to another style.
    /// For performance do direct comparisons first.
    pub fn eql(self: Style, other: Style) bool {
        inline for (comptime std.meta.fields(Style)) |field| {
            if (comptime std.meta.hasUniqueRepresentation(field.type)) {
                if (@field(self, field.name) != @field(other, field.name)) {
                    return false;
                }
            }
        }
        inline for (comptime std.meta.fields(Style)) |field| {
            if (comptime !std.meta.hasUniqueRepresentation(field.type)) {
                if (!std.meta.eql(@field(self, field.name), @field(other, field.name))) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Returns the bg color for a cell with this style given the cell
    /// that has this style and the palette to use.
    ///
    /// Note that generally if a cell is a color-only cell, it SHOULD
    /// only have the default style, but this is meant to work with the
    /// default style as well.
    pub fn bg(
        self: Style,
        cell: *const page.Cell,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (cell.content_tag) {
            .bg_color_palette => palette[cell.content.color_palette],
            .bg_color_rgb => rgb: {
                const rgb = cell.content.color_rgb;
                break :rgb .{ .r = rgb.r, .g = rgb.g, .b = rgb.b };
            },

            else => switch (self.bg_color) {
                .none => null,
                .palette => |idx| palette[idx],
                .rgb => |rgb| rgb,
            },
        };
    }

    pub const Fg = struct {
        /// The default color to use if the style doesn't specify a
        /// foreground color and no configuration options override
        /// it.
        default: color.RGB,

        /// The current color palette. Required to map palette indices to
        /// real color values.
        palette: *const color.Palette,

        /// If specified, the color to use for bold text.
        bold: ?configpkg.BoldColor = null,
    };

    /// Returns the fg color for a cell with this style given the palette
    /// and various configuration options.
    pub fn fg(
        self: Style,
        opts: Fg,
    ) color.RGB {
        // Note we don't pull the bold check to the top-level here because
        // we don't want to duplicate the conditional multiple times since
        // certain colors require more checks (e.g. `bold_is_bright`).

        return switch (self.fg_color) {
            .none => default: {
                if (self.flags.bold) {
                    if (opts.bold) |bold| switch (bold) {
                        .bright => {},
                        .color => |v| break :default v.toTerminalRGB(),
                    };
                }

                break :default opts.default;
            },

            .palette => |idx| palette: {
                if (self.flags.bold) {
                    if (opts.bold) |_| {
                        const bright_offset = @intFromEnum(color.Name.bright_black);
                        if (idx < bright_offset) {
                            break :palette opts.palette[idx + bright_offset];
                        }
                    }
                }

                break :palette opts.palette[idx];
            },

            .rgb => |rgb| rgb: {
                if (self.flags.bold and rgb.eql(opts.default)) {
                    if (opts.bold) |bold| switch (bold) {
                        .color => |v| break :rgb v.toTerminalRGB(),
                        .bright => {},
                    };
                }

                break :rgb rgb;
            },
        };
    }

    /// Returns the underline color for this style.
    pub fn underlineColor(
        self: Style,
        palette: *const color.Palette,
    ) ?color.RGB {
        return switch (self.underline_color) {
            .none => null,
            .palette => |idx| palette[idx],
            .rgb => |rgb| rgb,
        };
    }

    /// Returns a bg-color only cell from this style, if it exists.
    pub fn bgCell(self: Style) ?page.Cell {
        return switch (self.bg_color) {
            .none => null,
            .palette => |idx| .{
                .content_tag = .bg_color_palette,
                .content = .{ .color_palette = idx },
            },
            .rgb => |rgb| .{
                .content_tag = .bg_color_rgb,
                .content = .{ .color_rgb = .{
                    .r = rgb.r,
                    .g = rgb.g,
                    .b = rgb.b,
                } },
            },
        };
    }

    /// Formatting to make debug logs easier to read
    /// by only including non-default attributes.
    pub fn format(
        self: Style,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: *std.Io.Writer,
    ) !void {
        _ = fmt;
        _ = options;

        const dflt: Style = .{};

        _ = try writer.write("Style{ ");

        var started = false;

        inline for (std.meta.fields(Style)) |f| {
            if (std.mem.eql(u8, f.name, "flags")) {
                if (started) {
                    _ = try writer.write(", ");
                }

                _ = try writer.write("flags={ ");

                started = false;

                inline for (std.meta.fields(@TypeOf(self.flags))) |ff| {
                    const v = @as(ff.type, @field(self.flags, ff.name));
                    const d = @as(ff.type, @field(dflt.flags, ff.name));
                    if (ff.type == bool) {
                        if (v) {
                            if (started) {
                                _ = try writer.write(", ");
                            }
                            _ = try writer.print("{s}", .{ff.name});
                            started = true;
                        }
                    } else if (!std.meta.eql(v, d)) {
                        if (started) {
                            _ = try writer.write(", ");
                        }
                        _ = try writer.print(
                            "{s}={any}",
                            .{ ff.name, v },
                        );
                        started = true;
                    }
                }
                _ = try writer.write(" }");

                started = true;
                comptime continue;
            }
            const value = @as(f.type, @field(self, f.name));
            const d_val = @as(f.type, @field(dflt, f.name));
            if (!std.meta.eql(value, d_val)) {
                if (started) {
                    _ = try writer.write(", ");
                }
                _ = try writer.print(
                    "{s}={any}",
                    .{ f.name, value },
                );
                started = true;
            }
        }

        _ = try writer.write(" }");
    }

    /// Returns a formatter that renders this style as VT sequences,
    /// to be used with `{f}`. This always resets the style first `\x1b[0m`
    /// since a style is meant to be fully self-contained.
    ///
    /// For individual styles, this always emits multiple SGR sequences
    /// (i.e. an individual `\x1b[<stuff>m` for each attribute) rather than
    /// trying to combine them into a single sequence. We do this because
    /// terminals have varying levels of support for combined sequences
    /// especially with mixed separators (e.g. `:` vs `;`).
    pub fn formatterVt(self: *const Style) VTFormatter {
        return .{ .style = self };
    }

    /// Returns a formatter that renders this style as inline CSS properties,
    /// to be used with `{f}`. The output is a valid CSS style string suitable
    /// for use in a `style` attribute (e.g., "color: rgb(255, 0, 0); font-weight: bold;").
    ///
    /// Palette colors are emitted as CSS variables like `var(--vt-palette-N)`.
    pub fn formatterHtml(self: *const Style) HtmlFormatter {
        return .{ .style = self };
    }

    const VTFormatter = struct {
        style: *const Style,

        /// If set, palette colors will be emitted as RGB values instead of
        /// palette indices. This is useful when you want to capture the
        /// exact colors at formatting time rather than relying on the
        /// terminal's palette.
        palette: ?*const color.Palette = null,

        pub fn format(
            self: VTFormatter,
            writer: *std.Io.Writer,
        ) !void {
            // Always reset the style. Styles are fully self-contained.
            // Even if this style is empty, then that means we want to go
            // back to the default.
            try writer.writeAll("\x1b[0m");

            // Our flags
            if (self.style.flags.bold) try writer.writeAll("\x1b[1m");
            if (self.style.flags.faint) try writer.writeAll("\x1b[2m");
            if (self.style.flags.italic) try writer.writeAll("\x1b[3m");
            if (self.style.flags.blink) try writer.writeAll("\x1b[5m");
            if (self.style.flags.inverse) try writer.writeAll("\x1b[7m");
            if (self.style.flags.invisible) try writer.writeAll("\x1b[8m");
            if (self.style.flags.strikethrough) try writer.writeAll("\x1b[9m");
            if (self.style.flags.overline) try writer.writeAll("\x1b[53m");
            switch (self.style.flags.underline) {
                .none => {},
                .single => try writer.writeAll("\x1b[4m"),
                .double => try writer.writeAll("\x1b[4:2m"),
                .curly => try writer.writeAll("\x1b[4:3m"),
                .dotted => try writer.writeAll("\x1b[4:4m"),
                .dashed => try writer.writeAll("\x1b[4:5m"),
            }

            // Various RGB colors.
            try self.formatColor(writer, 38, self.style.fg_color);
            try self.formatColor(writer, 48, self.style.bg_color);
            try self.formatColor(writer, 58, self.style.underline_color);
        }

        fn formatColor(
            self: VTFormatter,
            writer: *std.Io.Writer,
            prefix: u8,
            value: Color,
        ) !void {
            switch (value) {
                .none => {},
                .palette => |idx| {
                    if (self.palette) |p| {
                        const rgb = p[idx];
                        try writer.print(
                            "\x1b[{d};2;{d};{d};{d}m",
                            .{ prefix, rgb.r, rgb.g, rgb.b },
                        );
                    } else {
                        try writer.print(
                            "\x1b[{d};5;{d}m",
                            .{ prefix, idx },
                        );
                    }
                },
                .rgb => |rgb| try writer.print(
                    "\x1b[{d};2;{d};{d};{d}m",
                    .{ prefix, rgb.r, rgb.g, rgb.b },
                ),
            }
        }
    };

    const HtmlFormatter = struct {
        style: *const Style,

        /// If set, palette colors will be emitted as RGB values instead of
        /// CSS variables. This is useful when you want to capture the exact
        /// colors at formatting time rather than relying on CSS variables.
        palette: ?*const color.Palette = null,

        pub fn format(
            self: HtmlFormatter,
            writer: *std.Io.Writer,
        ) !void {
            // Colors
            try self.formatColor(writer, "color", self.style.fg_color);
            try self.formatColor(writer, "background-color", self.style.bg_color);
            try self.formatColor(writer, "text-decoration-color", self.style.underline_color);

            // Text decoration line
            const has_line = self.style.flags.underline != .none or
                self.style.flags.strikethrough or
                self.style.flags.overline or
                self.style.flags.blink;
            if (has_line) {
                try writer.writeAll("text-decoration-line:");
                if (self.style.flags.underline != .none) try writer.writeAll(" underline");
                if (self.style.flags.strikethrough) try writer.writeAll(" line-through");
                if (self.style.flags.overline) try writer.writeAll(" overline");
                if (self.style.flags.blink) try writer.writeAll(" blink");
                try writer.writeAll(";");
            }

            // Text decoration style
            switch (self.style.flags.underline) {
                .none => {},
                .single => try writer.writeAll("text-decoration-style: solid;"),
                .double => try writer.writeAll("text-decoration-style: double;"),
                .curly => try writer.writeAll("text-decoration-style: wavy;"),
                .dotted => try writer.writeAll("text-decoration-style: dotted;"),
                .dashed => try writer.writeAll("text-decoration-style: dashed;"),
            }

            if (self.style.flags.bold) try writer.writeAll("font-weight: bold;");
            if (self.style.flags.italic) try writer.writeAll("font-style: italic;");
            if (self.style.flags.faint) try writer.writeAll("opacity: 0.5;");
            if (self.style.flags.invisible) try writer.writeAll("visibility: hidden;");
            if (self.style.flags.inverse) try writer.writeAll("filter: invert(100%);");
        }

        fn formatColor(
            self: HtmlFormatter,
            writer: *std.Io.Writer,
            property: []const u8,
            c: Color,
        ) !void {
            switch (c) {
                .none => {},
                .palette => |idx| {
                    if (self.palette) |p| {
                        const rgb = p[idx];
                        try writer.print("{s}: rgb({d}, {d}, {d});", .{ property, rgb.r, rgb.g, rgb.b });
                    } else {
                        try writer.print("{s}: var(--vt-palette-{d});", .{ property, idx });
                    }
                },
                .rgb => |rgb| try writer.print("{s}: rgb({d}, {d}, {d});", .{ property, rgb.r, rgb.g, rgb.b }),
            }
        }
    };

    /// `PackedStyle` represents the same data as `Style` but without padding,
    /// which is necessary for hashing via re-interpretation of the underlying
    /// bytes.
    ///
    /// `Style` is still preferred for everything else as it has type-safety
    /// when using the `Color` tagged union.
    ///
    /// Empirical testing shows that storing all of the tags first and then the
    /// data provides a better layout for serializing into and is faster on
    /// benchmarks.
    const PackedStyle = packed struct(u128) {
        tags: packed struct {
            fg: Color.Tag,
            bg: Color.Tag,
            underline: Color.Tag,
        },
        data: packed struct {
            fg: Data,
            bg: Data,
            underline: Data,
        },
        flags: Flags,
        _padding: u16 = 0,

        /// After https://github.com/ziglang/zig/issues/19754 is implemented,
        /// it will be an compiler-error to have packed union fields of
        /// differing size.
        ///
        /// For now we just need to be careful not to accidentally introduce
        /// padding.
        const Data = packed union {
            none: u24,
            palette: packed struct(u24) {
                idx: u8,
                _padding: u16 = 0,
            },
            rgb: color.RGB,

            fn fromColor(c: Color) Data {
                return switch (c) {
                    inline else => |v, t| @unionInit(
                        Data,
                        @tagName(t),
                        switch (t) {
                            .none => 0,
                            .palette => .{ .idx = v },
                            .rgb => v,
                        },
                    ),
                };
            }
        };

        fn fromStyle(style: Style) PackedStyle {
            return .{
                .tags = .{
                    .fg = std.meta.activeTag(style.fg_color),
                    .bg = std.meta.activeTag(style.bg_color),
                    .underline = std.meta.activeTag(style.underline_color),
                },
                .data = .{
                    .fg = .fromColor(style.fg_color),
                    .bg = .fromColor(style.bg_color),
                    .underline = .fromColor(style.underline_color),
                },
                .flags = style.flags,
            };
        }
    };

    pub fn hash(self: *const Style) u64 {
        const packed_style = PackedStyle.fromStyle(self.*);
        return std.hash.XxHash3.hash(0, std.mem.asBytes(&packed_style));
    }

    comptime {
        assert(@sizeOf(PackedStyle) == 16);
        assert(std.meta.hasUniqueRepresentation(PackedStyle));
        for (@typeInfo(PackedStyle.Data).@"union".fields) |field| {
            assert(@bitSizeOf(field.type) == @bitSizeOf(PackedStyle.Data));
        }
    }
};

pub const Set = RefCountedSet(
    Style,
    Id,
    size.CellCountInt,
    struct {
        pub fn hash(self: *const @This(), style: Style) u64 {
            _ = self;
            return style.hash();
        }

        pub fn eql(self: *const @This(), a: Style, b: Style) bool {
            _ = self;
            return a.eql(b);
        }
    },
);

test "Style VT formatting empty" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{};
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m", builder.writer.buffered());
}

test "Style VT formatting bold" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .bold = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[1m", builder.writer.buffered());
}

test "Style VT formatting faint" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .faint = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[2m", builder.writer.buffered());
}

test "Style VT formatting italic" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .italic = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[3m", builder.writer.buffered());
}

test "Style VT formatting blink" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .blink = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[5m", builder.writer.buffered());
}

test "Style VT formatting inverse" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .inverse = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[7m", builder.writer.buffered());
}

test "Style VT formatting invisible" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .invisible = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[8m", builder.writer.buffered());
}

test "Style VT formatting strikethrough" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .strikethrough = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[9m", builder.writer.buffered());
}

test "Style VT formatting overline" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .overline = true } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[53m", builder.writer.buffered());
}

test "Style VT formatting underline single" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .single } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[4m", builder.writer.buffered());
}

test "Style VT formatting underline double" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .double } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[4:2m", builder.writer.buffered());
}

test "Style VT formatting underline curly" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .curly } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[4:3m", builder.writer.buffered());
}

test "Style VT formatting underline dotted" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .dotted } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[4:4m", builder.writer.buffered());
}

test "Style VT formatting underline dashed" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .dashed } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[4:5m", builder.writer.buffered());
}

test "Style VT formatting fg palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .fg_color = .{ .palette = 42 } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[38;5;42m", builder.writer.buffered());
}

test "Style VT formatting fg rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .fg_color = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[38;2;255;128;64m", builder.writer.buffered());
}

test "Style VT formatting bg palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .bg_color = .{ .palette = 7 } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[48;5;7m", builder.writer.buffered());
}

test "Style VT formatting bg rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .bg_color = .{ .rgb = .{ .r = 32, .g = 64, .b = 96 } } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[48;2;32;64;96m", builder.writer.buffered());
}

test "Style VT formatting underline_color palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .underline_color = .{ .palette = 15 } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[58;5;15m", builder.writer.buffered());
}

test "Style VT formatting underline_color rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .underline_color = .{ .rgb = .{ .r = 200, .g = 100, .b = 50 } } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[58;2;200;100;50m", builder.writer.buffered());
}

test "Style VT formatting multiple flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .bold = true, .italic = true, .underline = .single } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings("\x1b[0m\x1b[1m\x1b[3m\x1b[4m", builder.writer.buffered());
}

test "Style VT formatting all flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{
        .bold = true,
        .faint = true,
        .italic = true,
        .blink = true,
        .inverse = true,
        .invisible = true,
        .strikethrough = true,
        .overline = true,
        .underline = .curly,
    } };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[1m\x1b[2m\x1b[3m\x1b[5m\x1b[7m\x1b[8m\x1b[9m\x1b[53m\x1b[4:3m",
        builder.writer.buffered(),
    );
}

test "Style VT formatting combined colors and flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } },
        .bg_color = .{ .palette = 8 },
        .underline_color = .{ .rgb = .{ .r = 0, .g = 255, .b = 0 } },
        .flags = .{ .bold = true, .italic = true, .underline = .double },
    };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[1m\x1b[3m\x1b[4:2m\x1b[38;2;255;0;0m\x1b[48;5;8m\x1b[58;2;0;255;0m",
        builder.writer.buffered(),
    );
}

test "Style VT formatting all colors rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .rgb = .{ .r = 10, .g = 20, .b = 30 } },
        .bg_color = .{ .rgb = .{ .r = 40, .g = 50, .b = 60 } },
        .underline_color = .{ .rgb = .{ .r = 70, .g = 80, .b = 90 } },
    };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[38;2;10;20;30m\x1b[48;2;40;50;60m\x1b[58;2;70;80;90m",
        builder.writer.buffered(),
    );
}

test "Style VT formatting all colors palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .palette = 1 },
        .bg_color = .{ .palette = 2 },
        .underline_color = .{ .palette = 3 },
    };
    try builder.writer.print("{f}", .{style.formatterVt()});
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[38;5;1m\x1b[48;5;2m\x1b[58;5;3m",
        builder.writer.buffered(),
    );
}

test "Style VT formatting palette with palette set emits rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .fg_color = .{ .palette = 1 } };
    var formatter = style.formatterVt();
    formatter.palette = &color.default;
    try builder.writer.print("{f}", .{formatter});
    try testing.expectEqualStrings("\x1b[0m\x1b[38;2;204;102;102m", builder.writer.buffered());
}

test "Style VT formatting all palette colors with palette set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .palette = 1 },
        .bg_color = .{ .palette = 2 },
        .underline_color = .{ .palette = 3 },
    };
    var formatter = style.formatterVt();
    formatter.palette = &color.default;
    try builder.writer.print("{f}", .{formatter});
    try testing.expectEqualStrings(
        "\x1b[0m\x1b[38;2;204;102;102m\x1b[48;2;181;189;104m\x1b[58;2;240;198;116m",
        builder.writer.buffered(),
    );
}

test "Set basic usage" {
    const testing = std.testing;
    const alloc = testing.allocator;
    const layout: Set.Layout = .init(16);
    const buf = try alloc.alignedAlloc(u8, Set.base_align, layout.total_size);
    defer alloc.free(buf);

    const style: Style = .{ .flags = .{ .bold = true } };
    const style2: Style = .{ .flags = .{ .italic = true } };

    var set = Set.init(.init(buf), layout, .{});

    // Add style
    const id = try set.add(buf, style);
    try testing.expect(id > 0);

    // Second add should return the same metadata.
    {
        const id2 = try set.add(buf, style);
        try testing.expectEqual(id, id2);
    }

    // Look it up
    {
        const v = set.get(buf, id);
        try testing.expect(v.flags.bold);

        const v2 = set.get(buf, id);
        try testing.expectEqual(v, v2);
    }

    // Add a second style
    const id2 = try set.add(buf, style2);

    // Look it up
    {
        const v = set.get(buf, id2);
        try testing.expect(v.flags.italic);
    }

    // Ref count
    try testing.expect(set.refCount(buf, id) == 2);
    try testing.expect(set.refCount(buf, id2) == 1);

    // Release
    set.release(buf, id);
    try testing.expect(set.refCount(buf, id) == 1);
    set.release(buf, id2);
    try testing.expect(set.refCount(buf, id2) == 0);

    // We added the first one twice, so
    set.release(buf, id);
    try testing.expect(set.refCount(buf, id) == 0);
}

test "Set capacities" {
    // We want to support at least this many styles without overflowing.
    _ = Set.Layout.init(16384);
}

test "Style HTML formatting basic bold" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .bold = true } };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    try testing.expectEqualStrings("font-weight: bold;", builder.writer.buffered());
}

test "Style HTML formatting fg color rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .fg_color = .{ .rgb = .{ .r = 255, .g = 128, .b = 64 } } };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    try testing.expectEqualStrings("color: rgb(255, 128, 64);", builder.writer.buffered());
}

test "Style HTML formatting bg color palette" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .bg_color = .{ .palette = 7 } };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    try testing.expectEqualStrings("background-color: var(--vt-palette-7);", builder.writer.buffered());
}

test "Style HTML formatting combined colors and flags" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .rgb = .{ .r = 255, .g = 0, .b = 0 } },
        .bg_color = .{ .rgb = .{ .r = 0, .g = 0, .b = 255 } },
        .flags = .{ .bold = true, .italic = true },
    };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    const result = builder.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "color: rgb(255, 0, 0);") != null);
    try testing.expect(std.mem.indexOf(u8, result, "background-color: rgb(0, 0, 255);") != null);
    try testing.expect(std.mem.indexOf(u8, result, "font-weight: bold;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "font-style: italic;") != null);
}

test "Style HTML formatting single decoration line" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .single } };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    const result = builder.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "text-decoration-line: underline;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "text-decoration-style: solid;") != null);
}

test "Style HTML formatting multiple decoration lines" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .flags = .{ .underline = .curly, .strikethrough = true, .overline = true } };
    try builder.writer.print("{f}", .{style.formatterHtml()});
    const result = builder.writer.buffered();
    try testing.expect(std.mem.indexOf(u8, result, "text-decoration-line: underline line-through overline;") != null);
    try testing.expect(std.mem.indexOf(u8, result, "text-decoration-style: wavy;") != null);
}

test "Style HTML formatting palette with palette set emits rgb" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{ .bg_color = .{ .palette = 7 } };
    var formatter = style.formatterHtml();
    formatter.palette = &color.default;
    try builder.writer.print("{f}", .{formatter});
    try testing.expectEqualStrings("background-color: rgb(197, 200, 198);", builder.writer.buffered());
}

test "Style HTML formatting all palette colors with palette set" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var builder: std.Io.Writer.Allocating = .init(alloc);
    defer builder.deinit();

    var style: Style = .{
        .fg_color = .{ .palette = 1 },
        .bg_color = .{ .palette = 2 },
        .underline_color = .{ .palette = 3 },
    };
    var formatter = style.formatterHtml();
    formatter.palette = &color.default;
    try builder.writer.print("{f}", .{formatter});
    try testing.expectEqualStrings(
        "color: rgb(204, 102, 102);background-color: rgb(181, 189, 104);text-decoration-color: rgb(240, 198, 116);",
        builder.writer.buffered(),
    );
}
