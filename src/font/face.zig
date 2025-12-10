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
            /// Use the full line height of the primary face for
            /// constraining this glyph.
            cell,
            /// Use the icon height from the grid metrics for
            /// constraining this glyph. Unlike `cell`, the value of
            /// this height depends on both the constraint width and the
            /// affected by the `adjust-icon-height` config option.
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

            switch (self.size) {
                .stretch => {
                    // Stretched glyphs are usually meant to align across cell
                    // boundaries, which works best if they're scaled and
                    // aligned to the grid rather than the face. This is most
                    // easily done by inserting this little fib in the metrics.
                    var m = metrics;
                    m.face_width = @floatFromInt(m.cell_width);
                    m.face_height = @floatFromInt(m.cell_height);
                    m.face_y = 0.0;

                    // Negative padding for stretched glyphs is a band-aid to
                    // avoid gaps due to pixel rounding, but at the cost of
                    // unsightly overlap artifacts. Since we scale and align to
                    // the grid rather than the face, we don't need it.
                    var c = self;
                    c.pad_bottom = @max(0, c.pad_bottom);
                    c.pad_top = @max(0, c.pad_top);
                    c.pad_left = @max(0, c.pad_left);
                    c.pad_right = @max(0, c.pad_right);

                    return c.constrainInner(glyph, m, constraint_width);
                },
                else => return self.constrainInner(glyph, metrics, constraint_width),
            }
        }

        fn constrainInner(
            self: Constraint,
            glyph: GlyphSize,
            metrics: Metrics,
            constraint_width: u2,
        ) GlyphSize {
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

            // Apply prescribed scaling, preserving the
            // center bearings of the group bounding box
            const width_factor, const height_factor = self.scale_factors(group, metrics, min_constraint_width);
            const center_x = group.x + (group.width / 2);
            const center_y = group.y + (group.height / 2);
            group.width *= width_factor;
            group.height *= height_factor;
            group.x = center_x - (group.width / 2);
            group.y = center_y - (group.height / 2);

            // NOTE: font_patcher jumps through a lot of hoops at this
            // point to ensure that the glyph remains within the target
            // bounding box after rounding to font definition units.
            // This is irrelevant here as we're not rounding, we're
            // staying in f64 and heading straight to rendering.

            // Apply prescribed alignment
            group.y = self.aligned_y(group, metrics);
            group.x = self.aligned_x(group, metrics, min_constraint_width);

            // Transfer the scaling and alignment back to the glyph and return.
            return .{
                .width = width_factor * glyph.width,
                .height = height_factor * glyph.height,
                .x = group.x + (group.width * self.relative_x),
                .y = group.y + (group.height * self.relative_y),
            };
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
                // Like font-patcher, the icon constraint height depends on the
                // constraint width. Unlike font-patcher, the multi-cell
                // icon_height may be different from face_height due to the
                // `adjust-icon-height` config option.
                .icon => if (multi_cell)
                    metrics.icon_height
                else
                    metrics.icon_height_single,
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

        /// Return vertical bearing for aligning this group
        fn aligned_y(
            self: Constraint,
            group: GlyphSize,
            metrics: Metrics,
        ) f64 {
            if ((self.size == .none) and (self.align_vertical == .none)) {
                // If we don't have any constraints affecting the vertical axis,
                // we don't touch vertical alignment.
                return group.y;
            }
            // We use face_height and offset by face_y, rather than
            // using cell_height directly, to account for the asymmetry
            // of the pixel cell around the face (a consequence of
            // aligning the baseline with a pixel boundary rather than
            // vertically centering the face).
            const pad_bottom_dy = self.pad_bottom * metrics.face_height;
            const pad_top_dy = self.pad_top * metrics.face_height;
            const start_y = metrics.face_y + pad_bottom_dy;
            const end_y = metrics.face_y + (metrics.face_height - group.height - pad_top_dy);
            const center_y = (start_y + end_y) / 2;
            return switch (self.align_vertical) {
                // NOTE: Even if there is no prescribed alignment, we ensure
                // that the group doesn't protrude outside the padded cell,
                // since this is implied by every available size constraint. If
                // the group is too high we fall back to centering, though if we
                // hit the .none prong we always have self.size != .none, so
                // this should never happen.
                .none => if (end_y < start_y)
                    center_y
                else
                    @max(start_y, @min(group.y, end_y)),
                .start => start_y,
                .end => end_y,
                .center, .center1 => center_y,
            };
        }

        /// Return horizontal bearing for aligning this group
        fn aligned_x(
            self: Constraint,
            group: GlyphSize,
            metrics: Metrics,
            min_constraint_width: u2,
        ) f64 {
            if ((self.size == .none) and (self.align_horizontal == .none)) {
                // If we don't have any constraints affecting the horizontal
                // axis, we don't touch horizontal alignment.
                return group.x;
            }
            // For multi-cell constraints, we align relative to the span
            // from the left edge of the first cell to the right edge of
            // the last face cell assuming it's left-aligned within the
            // rounded and adjusted pixel cell. Any horizontal offset to
            // center the face within the grid cell is the responsibility
            // of the backend-specific rendering code, and should be done
            // after applying constraints.
            const full_face_span = metrics.face_width + @as(f64, @floatFromInt((min_constraint_width - 1) * metrics.cell_width));
            const pad_left_dx = self.pad_left * metrics.face_width;
            const pad_right_dx = self.pad_right * metrics.face_width;
            const start_x = pad_left_dx;
            const end_x = full_face_span - group.width - pad_right_dx;
            return switch (self.align_horizontal) {
                // NOTE: Even if there is no prescribed alignment, we ensure
                // that the glyph doesn't protrude outside the padded cell,
                // since this is implied by every available size constraint. The
                // left-side bound has priority if the group is too wide, though
                // if we hit the .none prong we always have self.size != .none,
                // so this should never happen.
                .none => @max(start_x, @min(group.x, end_x)),
                .start => start_x,
                .end => @max(start_x, end_x),
                .center => @max(start_x, (start_x + end_x) / 2),
                // NOTE: .center1 implements the font_patcher rule of centering
                // in the first cell even for multi-cell constraints. Since glyphs
                // are not allowed to protrude to the left, this results in the
                // left-alignment like .start when the glyph is wider than a cell.
                .center1 => center1: {
                    const end1_x = metrics.face_width - group.width - pad_right_dx;
                    break :center1 @max(start_x, (start_x + end1_x) / 2);
                },
            };
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

test "Constraints" {
    const comparison = @import("../datastruct/comparison.zig");
    const getConstraint = @import("nerd_font_attributes.zig").getConstraint;

    // Hardcoded data matches metrics from CoreText at size 12 and DPI 96.

    // Define grid metrics (matches font-family = JetBrains Mono)
    const metrics: Metrics = .{
        .cell_width = 10,
        .cell_height = 22,
        .cell_baseline = 5,
        .underline_position = 19,
        .underline_thickness = 1,
        .strikethrough_position = 12,
        .strikethrough_thickness = 1,
        .overline_position = 0,
        .overline_thickness = 1,
        .box_thickness = 1,
        .cursor_thickness = 1,
        .cursor_height = 22,
        .icon_height = 21.12,
        .icon_height_single = 44.48 / 3.0,
        .face_width = 9.6,
        .face_height = 21.12,
        .face_y = 0.2,
    };

    // ASCII (no constraint).
    {
        const constraint: RenderOptions.Constraint = .none;

        // BBox of 'x' from JetBrains Mono.
        const glyph_x: GlyphSize = .{
            .width = 6.784,
            .height = 15.28,
            .x = 1.408,
            .y = 4.84,
        };

        // Any constraint width: do nothing.
        inline for (.{ 1, 2 }) |constraint_width| {
            try comparison.expectApproxEqual(
                glyph_x,
                constraint.constrain(glyph_x, metrics, constraint_width),
            );
        }
    }

    // Symbol (same constraint as hardcoded in Renderer.addGlyph).
    {
        const constraint: RenderOptions.Constraint = .{ .size = .fit };

        // BBox of '■' (0x25A0 black square) from Iosevka.
        // NOTE: This glyph is designed to span two cells.
        const glyph_25A0: GlyphSize = .{
            .width = 10.272,
            .height = 10.272,
            .x = 2.864,
            .y = 5.304,
        };

        // Constraint width 1: scale down and shift to fit a single cell.
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = metrics.face_width,
                .height = metrics.face_width,
                .x = 0,
                .y = 5.64,
            },
            constraint.constrain(glyph_25A0, metrics, 1),
        );

        // Constraint width 2: do nothing.
        try comparison.expectApproxEqual(
            glyph_25A0,
            constraint.constrain(glyph_25A0, metrics, 2),
        );
    }

    // Emoji (same constraint as hardcoded in SharedGrid.renderGlyph).
    {
        const constraint: RenderOptions.Constraint = .{
            .size = .cover,
            .align_horizontal = .center,
            .align_vertical = .center,
            .pad_left = 0.025,
            .pad_right = 0.025,
        };

        // BBox of '🥸' (0x1F978) from Apple Color Emoji.
        const glyph_1F978: GlyphSize = .{
            .width = 20,
            .height = 20,
            .x = 0.46,
            .y = 1,
        };

        // Constraint width 2: scale to cover two cells with padding, center;
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = 18.72,
                .height = 18.72,
                .x = 0.44,
                .y = 1.4,
            },
            constraint.constrain(glyph_1F978, metrics, 2),
        );
    }

    // Nerd Font default.
    {
        const constraint = getConstraint(0xea61).?;

        // Verify that this is the constraint we expect.
        try std.testing.expectEqual(.fit_cover1, constraint.size);
        try std.testing.expectEqual(.icon, constraint.height);
        try std.testing.expectEqual(.center1, constraint.align_horizontal);
        try std.testing.expectEqual(.center1, constraint.align_vertical);

        // BBox of '' (0xEA61 nf-cod-lightbulb) from Symbols Only.
        // NOTE: This icon is part of a group, so the
        // constraint applies to a larger bounding box.
        const glyph_EA61: GlyphSize = .{
            .width = 9.015625,
            .height = 13.015625,
            .x = 3.015625,
            .y = 3.76525,
        };

        // Constraint width 1: scale and shift group to fit a single cell.
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = 7.2125,
                .height = 10.4125,
                .x = 0.8125,
                .y = 5.950695224719102,
            },
            constraint.constrain(glyph_EA61, metrics, 1),
        );

        // Constraint width 2: no scaling; left-align and vertically center group.
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = glyph_EA61.width,
                .height = glyph_EA61.height,
                .x = 1.015625,
                .y = 4.7483690308988775,
            },
            constraint.constrain(glyph_EA61, metrics, 2),
        );
    }

    // Nerd Font stretch.
    {
        const constraint = getConstraint(0xe0c0).?;

        // Verify that this is the constraint we expect.
        try std.testing.expectEqual(.stretch, constraint.size);
        try std.testing.expectEqual(.cell, constraint.height);
        try std.testing.expectEqual(.start, constraint.align_horizontal);
        try std.testing.expectEqual(.center1, constraint.align_vertical);

        // BBox of ' ' (0xE0C0 nf-ple-flame_thick) from Symbols Only.
        const glyph_E0C0: GlyphSize = .{
            .width = 16.796875,
            .height = 16.46875,
            .x = -0.796875,
            .y = 1.7109375,
        };

        // Constraint width 1: stretch and position to exactly cover one cell.
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = @floatFromInt(metrics.cell_width),
                .height = @floatFromInt(metrics.cell_height),
                .x = 0,
                .y = 0,
            },
            constraint.constrain(glyph_E0C0, metrics, 1),
        );

        // Constraint width 1: stretch and position to exactly cover two cells.
        try comparison.expectApproxEqual(
            GlyphSize{
                .width = @floatFromInt(2 * metrics.cell_width),
                .height = @floatFromInt(metrics.cell_height),
                .x = 0,
                .y = 0,
            },
            constraint.constrain(glyph_E0C0, metrics, 2),
        );
    }
}
