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

/// The size and position of a glyph.
pub const GlyphSize = struct {
    width: f64,
    height: f64,
    x: f64,
    y: f64,
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

        /// Sizing rule.
        size: Size = .none,

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

        // Size and bearings of the glyph relative
        // to the bounding box of its scale group.
        relative_width: f64 = 1.0,
        relative_height: f64 = 1.0,
        relative_x: f64 = 0.0,
        relative_y: f64 = 0.0,

        /// Maximum aspect ratio (width/height) to allow when stretching.
        max_xy_ratio: ?f64 = null,

        /// Maximum number of cells horizontally to use.
        max_constraint_width: u2 = 2,

        /// What to use as the height metric when constraining the glyph and
        /// the constraint width is 1,
        height: Height = .cell,

        pub const Size = enum {
            /// Don't change the size of this glyph.
            none,
            /// Scale the glyph down if needed to fit within the bounds,
            /// preserving aspect ratio.
            fit,
            /// Scale the glyph up or down to exactly match the bounds,
            /// preserving aspect ratio.
            cover,
            /// Scale the glyph down if needed to fit within the bounds,
            /// preserving aspect ratio. If the glyph doesn't cover a
            /// single cell, scale up. If the glyph exceeds a single
            /// cell but is within the bounds, do nothing.
            /// (Nerd Font specific rule.)
            fit_cover1,
            /// Stretch the glyph to exactly fit the bounds in both
            /// directions, disregarding aspect ratio.
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
            /// Move the glyph so that it is centered on this axis,
            /// but always with respect to the first cell even for
            /// multi-cell constraints. (Nerd Font specific rule.)
            center1,
        };

        pub const Height = enum {
            /// Always use the full height of the cell for constraining this glyph.
            cell,
            /// When the constraint width is 1, use the "icon height" from the grid
            /// metrics as the height. (When the constraint width is >1, the
            /// constraint height is always the full cell height.)
            icon,
        };

        /// Returns true if the constraint does anything. If it doesn't,
        /// because it neither sizes nor positions the glyph, then this
        /// returns false.
        pub inline fn doesAnything(self: Constraint) bool {
            return self.size != .none or
                self.align_horizontal != .none or
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
            if (!self.doesAnything()) return glyph;

            // For extra wide font faces, never stretch glyphs across two cells.
            // This mirrors font_patcher.
            const min_constraint_width: u2 = if ((self.size == .stretch) and (metrics.face_width > 0.9 * metrics.face_height))
                1
            else
                @min(self.max_constraint_width, constraint_width);

            // The bounding box for the glyph's scale group.
            // Scaling and alignment rules are calculated for
            // this box and then applied to the glyph.
            var group: GlyphSize = group: {
                const group_width = glyph.width / self.relative_width;
                const group_height = glyph.height / self.relative_height;
                break :group .{
                    .width = group_width,
                    .height = group_height,
                    .x = glyph.x - (group_width * self.relative_x),
                    .y = glyph.y - (group_height * self.relative_y),
                };
            };

            // The new, constrained glyph size
            var constrained_glyph = glyph;

            // Apply prescribed scaling
            const width_factor, const height_factor = self.scale_factors(group, metrics, min_constraint_width);
            constrained_glyph.width *= width_factor;
            constrained_glyph.x *= width_factor;
            constrained_glyph.height *= height_factor;
            constrained_glyph.y *= height_factor;

            // NOTE: font_patcher jumps through a lot of hoops at this
            // point to ensure that the glyph remains within the target
            // bounding box after rounding to font definition units.
            // This is irrelevant here as we're not rounding, we're
            // staying in f64 and heading straight to rendering.

            // Align vertically
            if (self.align_vertical != .none) {
                // Vertically scale group bounding box.
                group.height *= height_factor;
                group.y *= height_factor;

                // Calculate offset and shift the glyph
                constrained_glyph.y += self.offset_vertical(group, metrics);
            }

            // Align horizontally
            if (self.align_horizontal != .none) {
                // Horizontally scale group bounding box.
                group.width *= width_factor;
                group.x *= width_factor;

                // Calculate offset and shift the glyph
                constrained_glyph.x += self.offset_horizontal(group, metrics, min_constraint_width);
            }

            return constrained_glyph;
        }

        /// Return width and height scaling factors for this scaling group.
        fn scale_factors(
            self: Constraint,
            group: GlyphSize,
            metrics: Metrics,
            min_constraint_width: u2,
        ) struct { f64, f64 } {
            if (self.size == .none) {
                return .{ 1.0, 1.0 };
            }

            const multi_cell = (min_constraint_width > 1);

            const pad_width_factor = @as(f64, @floatFromInt(min_constraint_width)) - (self.pad_left + self.pad_right);
            const pad_height_factor = 1 - (self.pad_bottom + self.pad_top);

            const target_width = pad_width_factor * metrics.face_width;
            const target_height = pad_height_factor * switch (self.height) {
                .cell => metrics.face_height,
                // icon_height only applies with single-cell constraints.
                // This mirrors font_patcher.
                .icon => if (multi_cell)
                    metrics.face_height
                else
                    metrics.icon_height,
            };

            var width_factor = target_width / group.width;
            var height_factor = target_height / group.height;

            switch (self.size) {
                .none => unreachable,
                .fit => {
                    // Scale down to fit if needed
                    height_factor = @min(1, width_factor, height_factor);
                    width_factor = height_factor;
                },
                .cover => {
                    // Scale to cover
                    height_factor = @min(width_factor, height_factor);
                    width_factor = height_factor;
                },
                .fit_cover1 => {
                    // Scale down to fit or up to cover at least one cell
                    // NOTE: This is similar to font_patcher's "pa" mode,
                    // however, font_patcher will only do the upscaling
                    // part if the constraint width is 1, resulting in
                    // some icons becoming smaller when the constraint
                    // width increases. You'd see icons shrinking when
                    // opening up a space after them. This makes no
                    // sense, so we've fixed the rule such that these
                    // icons are scaled to the same size for multi-cell
                    // constraints as they would be for single-cell.
                    height_factor = @min(width_factor, height_factor);
                    if (multi_cell and (height_factor > 1)) {
                        // Call back into this function with
                        // constraint width 1 to get single-cell scale
                        // factors. We use the height factor as width
                        // could have been modified by max_xy_ratio.
                        _, const single_height_factor = self.scale_factors(group, metrics, 1);
                        height_factor = @max(1, single_height_factor);
                    }
                    width_factor = height_factor;
                },
                .stretch => {},
            }

            // Reduce aspect ratio if required
            if (self.max_xy_ratio) |ratio| {
                if (group.width * width_factor > group.height * height_factor * ratio) {
                    width_factor = group.height * height_factor * ratio / group.width;
                }
            }

            return .{ width_factor, height_factor };
        }

        /// Return vertical offset needed to align this group
        fn offset_vertical(
            self: Constraint,
            group: GlyphSize,
            metrics: Metrics,
        ) f64 {
            // We use face_height and offset by face_y, rather than
            // using cell_height directly, to account for the asymmetry
            // of the pixel cell around the face (a consequence of
            // aligning the baseline with a pixel boundary rather than
            // vertically centering the face).
            const new_group_y = metrics.face_y + switch (self.align_vertical) {
                .none => return 0.0,
                .start => self.pad_bottom * metrics.face_height,
                .end => end: {
                    const pad_top_dy = self.pad_top * metrics.face_height;
                    break :end metrics.face_height - pad_top_dy - group.height;
                },
                .center, .center1 => (metrics.face_height - group.height) / 2,
            };
            return new_group_y - group.y;
        }

        /// Return horizontal offset needed to align this group
        fn offset_horizontal(
            self: Constraint,
            group: GlyphSize,
            metrics: Metrics,
            min_constraint_width: u2,
        ) f64 {
            // For multi-cell constraints, we align relative to the span
            // from the left edge of the first face cell to the right
            // edge of the last face cell as they sit within the rounded
            // and adjusted pixel cell (centered if narrower than the
            // pixel cell, left-aligned if wider).
            const face_x, const full_face_span = facecalcs: {
                const cell_width: f64 = @floatFromInt(metrics.cell_width);
                const full_width: f64 = @floatFromInt(min_constraint_width * metrics.cell_width);
                const cell_margin = cell_width - metrics.face_width;
                break :facecalcs .{ @max(0, cell_margin / 2), full_width - cell_margin };
            };
            const pad_left_x = self.pad_left * metrics.face_width;
            const new_group_x = face_x + switch (self.align_horizontal) {
                .none => return 0.0,
                .start => pad_left_x,
                .end => end: {
                    const pad_right_dx = self.pad_right * metrics.face_width;
                    break :end @max(pad_left_x, full_face_span - pad_right_dx - group.width);
                },
                .center => @max(pad_left_x, (full_face_span - group.width) / 2),
                // NOTE: .center1 implements the font_patcher rule of centering
                // in the first cell even for multi-cell constraints. Since glyphs
                // are not allowed to protrude to the left, this results in the
                // left-alignment like .start when the glyph is wider than a cell.
                .center1 => @max(pad_left_x, (metrics.face_width - group.width) / 2),
            };
            return new_group_x - group.x;
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
