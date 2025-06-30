const std = @import("std");
const assert = std.debug.assert;
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
            writer: anytype,
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
    pub fn eql(self: Style, other: Style) bool {
        // We convert the styles to packed structs and compare as integers
        // because this is much faster than comparing each field separately.
        return PackedStyle.fromStyle(self) == PackedStyle.fromStyle(other);
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

    /// Returns the fg color for a cell with this style given the palette.
    pub fn fg(
        self: Style,
        palette: *const color.Palette,
        bold_is_bright: bool,
    ) ?color.RGB {
        return switch (self.fg_color) {
            .none => null,
            .palette => |idx| palette: {
                if (bold_is_bright and self.flags.bold) {
                    const bright_offset = @intFromEnum(color.Name.bright_black);
                    if (idx < bright_offset)
                        break :palette palette[idx + bright_offset];
                }

                break :palette palette[idx];
            },
            .rgb => |rgb| rgb,
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
        writer: anytype,
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
