const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");
const options = @import("main.zig").options;
const Metrics = @import("main.zig").Metrics;
const config = @import("../config.zig");
const freetype = @import("face/freetype.zig");
const coretext = @import("face/coretext.zig");
pub const web_canvas = @import("face/web_canvas.zig");

/// Face implementation for the compile options.
pub const Face = switch (options.backend) {
    .freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    => freetype.Face,

    .coretext,
    .coretext_harfbuzz,
    .coretext_noshape,
    => coretext.Face,

    .web_canvas => web_canvas.Face,
};

/// If a DPI can't be calculated, this DPI is used. This is probably
/// wrong on modern devices so it is highly recommended you get the DPI
/// using whatever platform method you can.
pub const default_dpi = if (builtin.os.tag == .macos) 72 else 96;

/// These are the flags to customize how freetype loads fonts. This is
/// only non-void if the freetype backend is enabled.
pub const FreetypeLoadFlags = if (options.backend.hasFreetype())
    config.FreetypeLoadFlags
else
    void;
pub const freetype_load_flags_default: FreetypeLoadFlags = if (FreetypeLoadFlags != void) .{} else {};

/// Options for initializing a font face.
pub const Options = struct {
    size: DesiredSize,
    freetype_load_flags: FreetypeLoadFlags = freetype_load_flags_default,
};

/// The desired size for loading a font.
pub const DesiredSize = struct {
    // Desired size in points
    points: f32,

    // The DPI of the screen so we can convert points to pixels.
    xdpi: u16 = default_dpi,
    ydpi: u16 = default_dpi,

    // Converts points to pixels
    pub fn pixels(self: DesiredSize) f32 {
        // 1 point = 1/72 inch
        return (self.points * @as(f32, @floatFromInt(self.ydpi))) / 72;
    }

    /// Make this a valid gobject if we're in a GTK environment.
    pub const getGObjectType = switch (build_config.app_runtime) {
        .gtk => @import("gobject").ext.defineBoxed(
            DesiredSize,
            .{ .name = "GhosttyFontDesiredSize" },
        ),

        .none => void,
    };
};

/// A font variation setting. The best documentation for this I know of
/// is actually the CSS font-variation-settings property on MDN:
/// https://developer.mozilla.org/en-US/docs/Web/CSS/font-variation-settings
pub const Variation = struct {
    id: Id,
    value: f64,

    pub const Id = packed struct(u32) {
        d: u8,
        c: u8,
        b: u8,
        a: u8,

        pub fn init(v: *const [4]u8) Id {
            return .{ .a = v[0], .b = v[1], .c = v[2], .d = v[3] };
        }

        /// Converts the ID to a string. The return value is only valid
        /// for the lifetime of the self pointer.
        pub fn str(self: Id) [4]u8 {
            return .{ self.a, self.b, self.c, self.d };
        }
    };
};

/// Additional options for rendering glyphs.
pub const RenderOptions = struct {
    /// The metrics that are defining the grid layout. These are usually
    /// the metrics of the primary font face. The grid metrics are used
    /// by the font face to better layout the glyph in situations where
    /// the font is not exactly the same size as the grid.
    grid_metrics: Metrics,

    /// The number of grid cells this glyph will take up. This can be used
    /// optionally by the rasterizer to better layout the glyph.
    cell_width: ?u2 = null,

    /// Constraint and alignment properties for the glyph. The rasterizer
    /// should call the `constrain` function on this with the original size
    /// and bearings of the glyph to get remapped values that the glyph
    /// should be scaled/moved to.
    constraint: Constraint = .none,

    /// The number of cells, horizontally that the glyph is free to take up
    /// when resized and aligned by `constraint`. This is usually 1, but if
    /// there's whitespace to the right of the cell then it can be 2.
    constraint_width: u2 = 1,

    /// Thicken the glyph. This draws the glyph with a thicker stroke width.
    /// This is purely an aesthetic setting.
    ///
    /// This only works with CoreText currently.
    thicken: bool = false,

    /// "Strength" of the thickening, between `0` and `255`.
    /// Only has an effect when `thicken` is enabled.
    ///
    /// `0` does not correspond to *no* thickening,
    /// just the *lightest* thickening available.
    ///
    /// CoreText only.
    thicken_strength: u8 = 255,

    /// See the `constraint` field.
    pub const Constraint = struct {
        /// Don't constrain the glyph in any way.
        pub const none: Constraint = .{};

        /// Vertical sizing rule.
        size_vertical: Size = .none,
        /// Horizontal sizing rule.
        size_horizontal: Size = .none,

        /// Vertical alignment rule.
        align_vertical: Align = .none,
        /// Horizontal alignment rule.
        align_horizontal: Align = .none,

        /// Top padding when resizing.
        pad_top: f64 = 0.0,
        /// Left padding when resizing.
        pad_left: f64 = 0.0,
        /// Right padding when resizing.
        pad_right: f64 = 0.0,
        /// Bottom padding when resizing.
        pad_bottom: f64 = 0.0,

        // This acts as a multiple of the provided width when applying
        // constraints, so if this is 1.6 for example, then a width of
        // 10 would be treated as though it were 16.
        group_width: f64 = 1.0,
        // This acts as a multiple of the provided height when applying
        // constraints, so if this is 1.6 for example, then a height of
        // 10 would be treated as though it were 16.
        group_height: f64 = 1.0,
        // This is an x offset for the actual width within the group width.
        // If this is 0.5 then the glyph will be offset so that its left
        // edge sits at the halfway point of the group width.
        group_x: f64 = 0.0,
        // This is a y offset for the actual height within the group height.
        // If this is 0.5 then the glyph will be offset so that its bottom
        // edge sits at the halfway point of the group height.
        group_y: f64 = 0.0,

        /// Maximum ratio of width to height when resizing.
        max_xy_ratio: ?f64 = null,

        /// Maximum number of cells horizontally to use.
        max_constraint_width: u2 = 2,

        /// What to use as the height metric when constraining the glyph.
        height: Height = .cell,

        pub const Size = enum {
            /// Don't change the size of this glyph.
            none,
            /// Move the glyph and optionally scale it down
            /// proportionally to fit within the given axis.
            fit,
            /// Move and resize the glyph proportionally to
            /// cover the given axis.
            cover,
            /// Same as `cover` but not proportional.
            stretch,
        };

        pub const Align = enum {
            /// Don't move the glyph on this axis.
            none,
            /// Move the glyph so that its leading (bottom/left)
            /// edge aligns with the leading edge of the axis.
            start,
            /// Move the glyph so that its trailing (top/right)
            /// edge aligns with the trailing edge of the axis.
            end,
            /// Move the glyph so that it is centered on this axis.
            center,
        };

        pub const Height = enum {
            /// Use the full height of the cell for constraining this glyph.
            cell,
            /// Use the "icon height" from the grid metrics as the height.
            icon,
        };

        /// The size and position of a glyph.
        pub const GlyphSize = struct {
            width: f64,
            height: f64,
            x: f64,
            y: f64,
        };

        /// Returns true if the constraint does anything. If it doesn't,
        /// because it neither sizes nor positions the glyph, then this
        /// returns false.
        pub inline fn doesAnything(self: Constraint) bool {
            return self.size_horizontal != .none or
                self.align_horizontal != .none or
                self.size_vertical != .none or
                self.align_vertical != .none;
        }

        /// Apply this constraint to the provided glyph
        /// size, given the available width and height.
        pub fn constrain(
            self: Constraint,
            glyph: GlyphSize,
            metrics: Metrics,
            /// Number of cells horizontally available for this glyph.
            constraint_width: u2,
        ) GlyphSize {
            var g = glyph;

            const available_width: f64 = @floatFromInt(
                metrics.cell_width * @min(
                    self.max_constraint_width,
                    constraint_width,
                ),
            );
            const available_height: f64 = @floatFromInt(switch (self.height) {
                .cell => metrics.cell_height,
                .icon => metrics.icon_height,
            });

            const w = available_width -
                self.pad_left * available_width -
                self.pad_right * available_width;
            const h = available_height -
                self.pad_top * available_height -
                self.pad_bottom * available_height;

            // Subtract padding from the bearings so that our
            // alignment and sizing code works correctly. We
            // re-add before returning.
            g.x -= self.pad_left * available_width;
            g.y -= self.pad_bottom * available_height;

            // Multiply by group width and height for better sizing.
            g.width *= self.group_width;
            g.height *= self.group_height;

            switch (self.size_horizontal) {
                .none => {},
                .fit => if (g.width > w) {
                    const orig_height = g.height;
                    // Adjust our height and width to proportionally
                    // scale them to fit the glyph to the cell width.
                    g.height *= w / g.width;
                    g.width = w;
                    // Set our x to 0 since anything else would mean
                    // the glyph extends outside of the cell width.
                    g.x = 0;
                    // Compensate our y to keep things vertically
                    // centered as they're scaled down.
                    g.y += (orig_height - g.height) / 2;
                } else if (g.width + g.x > w) {
                    // If the width of the glyph can fit in the cell but
                    // is currently outside due to the left bearing, then
                    // we reduce the left bearing just enough to fit it
                    // back in the cell.
                    g.x = w - g.width;
                } else if (g.x < 0) {
                    g.x = 0;
                },
                .cover => {
                    const orig_height = g.height;

                    g.height *= w / g.width;
                    g.width = w;

                    g.x = 0;

                    g.y += (orig_height - g.height) / 2;
                },
                .stretch => {
                    g.width = w;
                    g.x = 0;
                },
            }

            switch (self.size_vertical) {
                .none => {},
                .fit => if (g.height > h) {
                    const orig_width = g.width;
                    // Adjust our height and width to proportionally
                    // scale them to fit the glyph to the cell height.
                    g.width *= h / g.height;
                    g.height = h;
                    // Set our y to 0 since anything else would mean
                    // the glyph extends outside of the cell height.
                    g.y = 0;
                    // Compensate our x to keep things horizontally
                    // centered as they're scaled down.
                    g.x += (orig_width - g.width) / 2;
                } else if (g.height + g.y > h) {
                    // If the height of the glyph can fit in the cell but
                    // is currently outside due to the bottom bearing, then
                    // we reduce the bottom bearing just enough to fit it
                    // back in the cell.
                    g.y = h - g.height;
                } else if (g.y < 0) {
                    g.y = 0;
                },
                .cover => {
                    const orig_width = g.width;

                    g.width *= h / g.height;
                    g.height = h;

                    g.y = 0;

                    g.x += (orig_width - g.width) / 2;
                },
                .stretch => {
                    g.height = h;
                    g.y = 0;
                },
            }

            // Add group-relative position
            g.x += self.group_x * g.width;
            g.y += self.group_y * g.height;

            // Divide group width and height back out before we align.
            g.width /= self.group_width;
            g.height /= self.group_height;

            if (self.max_xy_ratio) |ratio| if (g.width > g.height * ratio) {
                const orig_width = g.width;
                g.width = g.height * ratio;
                g.x += (orig_width - g.width) / 2;
            };

            switch (self.align_horizontal) {
                .none => {},
                .start => g.x = 0,
                .end => g.x = w - g.width,
                .center => g.x = (w - g.width) / 2,
            }

            switch (self.align_vertical) {
                .none => {},
                .start => g.y = 0,
                .end => g.y = h - g.height,
                .center => g.y = (h - g.height) / 2,
            }

            // Re-add our padding before returning.
            g.x += self.pad_left * available_width;
            g.y += self.pad_bottom * available_height;

            // If the available height is less than the cell height, we
            // add half of the difference to center it in the full height.
            //
            // If necessary, in the future, we can adjust this to account
            // for alignment, but that isn't necessary with any of the nf
            // icons afaict.
            const cell_height: f64 = @floatFromInt(metrics.cell_height);
            g.y += (cell_height - available_height) / 2;

            return g;
        }
    };
};

test {
    @import("std").testing.refAllDecls(@This());
}

test "Variation.Id: wght should be 2003265652" {
    const testing = std.testing;
    const id = Variation.Id.init("wght");
    try testing.expectEqual(@as(u32, 2003265652), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("wght", &(id.str()));
}

test "Variation.Id: slnt should be 1936486004" {
    const testing = std.testing;
    const id: Variation.Id = .{ .a = 's', .b = 'l', .c = 'n', .d = 't' };
    try testing.expectEqual(@as(u32, 1936486004), @as(u32, @bitCast(id)));
    try testing.expectEqualStrings("slnt", &(id.str()));
}
