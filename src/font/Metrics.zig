const Metrics = @This();

const std = @import("std");

/// Recommended cell width and height for a monospace grid using this font.
cell_width: u32,
cell_height: u32,

/// Distance in pixels from the bottom of the cell to the text baseline.
cell_baseline: u32,

/// Distance in pixels from the top of the cell to the top of the underline.
underline_position: u32,
/// Thickness in pixels of the underline.
underline_thickness: u32,

/// Distance in pixels from the top of the cell to the top of the strikethrough.
strikethrough_position: u32,
/// Thickness in pixels of the strikethrough.
strikethrough_thickness: u32,

/// Distance in pixels from the top of the cell to the top of the overline.
/// Can be negative to adjust the position above the top of the cell.
overline_position: i32,
/// Thickness in pixels of the overline.
overline_thickness: u32,

/// Thickness in pixels of box drawing characters.
box_thickness: u32,

/// The thickness in pixels of the cursor sprite. This has a default value
/// because it is not determined by fonts but rather by user configuration.
cursor_thickness: u32 = 1,

/// The height in pixels of the cursor sprite.
cursor_height: u32,

/// The constraint height for nerd fonts icons.
icon_height: f64,

/// The unrounded face width, used in scaling calculations.
face_width: f64,

/// The unrounded face height, used in scaling calculations.
face_height: f64,

/// The vertical bearing of face within the pixel-rounded
/// and possibly height-adjusted cell
face_y: f64,

/// Minimum acceptable values for some fields to prevent modifiers
/// from being able to, for example, cause 0-thickness underlines.
const Minimums = struct {
    const cell_width = 1;
    const cell_height = 1;
    const underline_thickness = 1;
    const strikethrough_thickness = 1;
    const overline_thickness = 1;
    const box_thickness = 1;
    const cursor_thickness = 1;
    const cursor_height = 1;
    const icon_height = 1.0;
    const face_height = 1.0;
    const face_width = 1.0;
};

/// Metrics extracted from a font face, based on
/// the metadata tables and glyph measurements.
pub const FaceMetrics = struct {
    /// Pixels per em, dividing the other values in this struct by this should
    /// yield sizes in ems, to allow comparing metrics from faces of different
    /// sizes.
    px_per_em: f64,

    /// The minimum cell width that can contain any glyph in the ASCII range.
    ///
    /// Determined by measuring all printable glyphs in the ASCII range.
    cell_width: f64,

    /// The typographic ascent metric from the font.
    /// This represents the maximum vertical position of the highest ascender.
    ///
    /// Relative to the baseline, in px, +Y=up
    ascent: f64,

    /// The typographic descent metric from the font.
    /// This represents the minimum vertical position of the lowest descender.
    ///
    /// Relative to the baseline, in px, +Y=up
    ///
    /// Note:
    /// As this value is generally below the baseline, it is typically negative.
    descent: f64,

    /// The typographic line gap (aka "leading") metric from the font.
    /// This represents the additional space to be added between lines in
    /// addition to the space defined by the ascent and descent metrics.
    ///
    /// Positive value in px
    line_gap: f64,

    /// The TOP of the underline stroke.
    ///
    /// Relative to the baseline, in px, +Y=up
    underline_position: ?f64 = null,

    /// The thickness of the underline stroke in px.
    underline_thickness: ?f64 = null,

    /// The TOP of the strikethrough stroke.
    ///
    /// Relative to the baseline, in px, +Y=up
    strikethrough_position: ?f64 = null,

    /// The thickness of the strikethrough stroke in px.
    strikethrough_thickness: ?f64 = null,

    /// The height of capital letters in the font, either derived from
    /// a provided cap height metric or measured from the height of the
    /// capital H glyph.
    cap_height: ?f64 = null,

    /// The height of lowercase letters in the font, either derived from
    /// a provided ex height metric or measured from the height of the
    /// lowercase x glyph.
    ex_height: ?f64 = null,

    /// The measured height of the bounding box containing all printable
    /// ASCII characters. This can be different from ascent - descent for
    /// two reasons: non-letter symbols like @ and $ often exceed the
    /// the ascender and descender lines; and fonts often bake the line
    /// gap into the ascent and descent metrics (as per, e.g., the Google
    /// Fonts guidelines: https://simoncozens.github.io/gf-docs/metrics.html).
    ///
    /// Positive value in px
    ascii_height: ?f64 = null,

    /// The width of the character "水" (CJK water ideograph, U+6C34),
    /// if present. This is used for font size adjustment, to normalize
    /// the width of CJK fonts mixed with latin fonts.
    ///
    /// NOTE: IC = Ideograph Character
    ic_width: ?f64 = null,

    /// Convenience function for getting the line height
    /// (ascent - descent + line_gap).
    pub inline fn lineHeight(self: FaceMetrics) f64 {
        return self.ascent - self.descent + self.line_gap;
    }

    /// Convenience function for getting the cap height. If this is not
    /// defined in the font, we estimate it as 75% of the ascent.
    pub inline fn capHeight(self: FaceMetrics) f64 {
        if (self.cap_height) |value| if (value > 0) return value;
        return 0.75 * self.ascent;
    }

    /// Convenience function for getting the ex height. If this is not
    /// defined in the font, we estimate it as 75% of the cap height.
    pub inline fn exHeight(self: FaceMetrics) f64 {
        if (self.ex_height) |value| if (value > 0) return value;
        return 0.75 * self.capHeight();
    }

    /// Convenience function for getting the ASCII height. If we
    /// couldn't measure this, we use 1.5 * cap_height as our
    /// estimator, based on measurements across programming fonts.
    pub inline fn asciiHeight(self: FaceMetrics) f64 {
        if (self.ascii_height) |value| if (value > 0) return value;
        return 1.5 * self.capHeight();
    }

    /// Convenience function for getting the ideograph width. If this is
    /// not defined in the font, we estimate it as the minimum of the
    /// ascii height and two cell widths.
    pub inline fn icWidth(self: FaceMetrics) f64 {
        if (self.ic_width) |value| if (value > 0) return value;
        return @min(self.asciiHeight(), 2 * self.cell_width);
    }

    /// Convenience function for getting the underline thickness. If
    /// this is not defined in the font, we estimate it as 15% of the ex
    /// height.
    pub inline fn underlineThickness(self: FaceMetrics) f64 {
        if (self.underline_thickness) |value| if (value > 0) return value;
        return 0.15 * self.exHeight();
    }

    /// Convenience function for getting the strikethrough thickness. If
    /// this is not defined in the font, we set it equal to the
    /// underline thickness.
    pub inline fn strikethroughThickness(self: FaceMetrics) f64 {
        if (self.strikethrough_thickness) |value| if (value > 0) return value;
        return self.underlineThickness();
    }

    // NOTE: The getters below return positions, not sizes, so both
    // positive and negative values are valid, hence no sign validation.

    /// Convenience function for getting the underline position. If
    /// this is not defined in the font, we place it one underline
    /// thickness below the baseline.
    pub inline fn underlinePosition(self: FaceMetrics) f64 {
        return self.underline_position orelse -self.underlineThickness();
    }

    /// Convenience function for getting the strikethrough position. If
    /// this is not defined in the font, we center it at half the ex
    /// height, so that it's perfectly centered on lower case text.
    pub inline fn strikethroughPosition(self: FaceMetrics) f64 {
        return self.strikethrough_position orelse (self.exHeight() + self.strikethroughThickness()) * 0.5;
    }
};

/// Calculate our metrics based on values extracted from a font.
///
/// Try to pass values with as much precision as possible,
/// do not round them before using them for this function.
///
/// For any nullable options that are not provided, estimates will be used.
pub fn calc(face: FaceMetrics) Metrics {
    // We use the ceiling of the provided cell width and height to ensure
    // that the cell is large enough for the provided size, since we cast
    // it to an integer later.
    const face_width = face.cell_width;
    const face_height = face.lineHeight();
    const cell_width = @ceil(face_width);
    const cell_height = @ceil(face_height);

    // We split our line gap in two parts, and put half of it on the top
    // of the cell and the other half on the bottom, so that our text never
    // bumps up against either edge of the cell vertically.
    const half_line_gap = face.line_gap / 2;

    // Unlike all our other metrics, `cell_baseline` is relative to the
    // BOTTOM of the cell.
    const face_baseline = half_line_gap - face.descent;
    const cell_baseline = @round(face_baseline);

    // We keep track of the vertical bearing of the face in the cell
    const face_y = cell_baseline - face_baseline;

    // We calculate a top_to_baseline to make following calculations simpler.
    const top_to_baseline = cell_height - cell_baseline;

    // Get the other font metrics or their estimates. See doc comments
    // in FaceMetrics for explanations of the estimation heuristics.
    const cap_height = face.capHeight();
    const underline_thickness = @max(1, @ceil(face.underlineThickness()));
    const strikethrough_thickness = @max(1, @ceil(face.strikethroughThickness()));
    const underline_position = @round(top_to_baseline - face.underlinePosition());
    const strikethrough_position = @round(top_to_baseline - face.strikethroughPosition());

    // Same heuristic as the font_patcher script
    const icon_height = (2 * cap_height + face_height) / 3;

    var result: Metrics = .{
        .cell_width = @intFromFloat(cell_width),
        .cell_height = @intFromFloat(cell_height),
        .cell_baseline = @intFromFloat(cell_baseline),
        .underline_position = @intFromFloat(underline_position),
        .underline_thickness = @intFromFloat(underline_thickness),
        .strikethrough_position = @intFromFloat(strikethrough_position),
        .strikethrough_thickness = @intFromFloat(strikethrough_thickness),
        .overline_position = 0,
        .overline_thickness = @intFromFloat(underline_thickness),
        .box_thickness = @intFromFloat(underline_thickness),
        .cursor_height = @intFromFloat(cell_height),
        .icon_height = icon_height,
        .face_width = face_width,
        .face_height = face_height,
        .face_y = face_y,
    };

    // Ensure all metrics are within their allowable range.
    result.clamp();

    // std.log.debug("metrics={}", .{result});

    return result;
}

/// Apply a set of modifiers.
pub fn apply(self: *Metrics, mods: ModifierSet) void {
    var it = mods.iterator();
    while (it.next()) |entry| {
        switch (entry.key_ptr.*) {
            // We clamp these values to a minimum of 1 to prevent divide-by-zero
            // in downstream operations.
            inline .cell_width,
            .cell_height,
            => |tag| {
                // Compute the new value. If it is the same avoid the work.
                const original = @field(self, @tagName(tag));
                const new = @max(entry.value_ptr.apply(original), 1);
                if (new == original) continue;

                // Set the new value
                @field(self, @tagName(tag)) = new;

                // For cell height, we have to also modify some positions
                // that are absolute from the top of the cell. The main goal
                // here is to center the baseline so that text is vertically
                // centered in the cell.
                if (comptime tag == .cell_height) {
                    // We split the difference in half because we want to
                    // center the baseline in the cell. If the difference
                    // is odd, one more pixel is added/removed on top than
                    // on the bottom.
                    if (new > original) {
                        const diff = new - original;
                        const diff_bottom = diff / 2;
                        const diff_top = diff - diff_bottom;
                        self.face_y += @floatFromInt(diff_bottom);
                        self.cell_baseline +|= diff_bottom;
                        self.underline_position +|= diff_top;
                        self.strikethrough_position +|= diff_top;
                        self.overline_position +|= @as(i32, @intCast(diff_top));
                    } else {
                        const diff = original - new;
                        const diff_bottom = diff / 2;
                        const diff_top = diff - diff_bottom;
                        self.face_y -= @floatFromInt(diff_bottom);
                        self.cell_baseline -|= diff_bottom;
                        self.underline_position -|= diff_top;
                        self.strikethrough_position -|= diff_top;
                        self.overline_position -|= @as(i32, @intCast(diff_top));
                    }
                }
            },

            inline else => |tag| {
                @field(self, @tagName(tag)) = entry.value_ptr.apply(@field(self, @tagName(tag)));
            },
        }
    }

    // Prevent modifiers from pushing metrics out of their allowable range.
    self.clamp();
}

/// Clamp all metrics to their allowable range.
fn clamp(self: *Metrics) void {
    inline for (std.meta.fields(Metrics)) |field| {
        if (@hasDecl(Minimums, field.name)) {
            @field(self, field.name) = @max(
                @field(self, field.name),
                @field(Minimums, field.name),
            );
        }
    }
}

/// A set of modifiers to apply to metrics. We use a hash map because
/// we expect most metrics to be unmodified and want to take up as
/// little space as possible.
pub const ModifierSet = std.AutoHashMapUnmanaged(Key, Modifier);

/// A modifier to apply to a metrics value. The modifier value represents
/// a delta, so percent is a percentage to change, not a percentage of.
/// For example, "20%" is 20% larger, not 20% of the value. Likewise,
/// an absolute value of "20" is 20 larger, not literally 20.
pub const Modifier = union(enum) {
    percent: f64,
    absolute: i32,

    /// Parses the modifier value. If the value ends in "%" it is assumed
    /// to be a percent, otherwise the value is parsed as an integer.
    pub fn parse(input: []const u8) !Modifier {
        if (input.len == 0) return error.InvalidFormat;

        if (input[input.len - 1] == '%') {
            var percent = std.fmt.parseFloat(
                f64,
                input[0 .. input.len - 1],
            ) catch return error.InvalidFormat;
            percent /= 100;

            if (percent <= -1) return .{ .percent = 0 };
            if (percent < 0) return .{ .percent = 1 + percent };
            return .{ .percent = 1 + percent };
        }

        return .{
            .absolute = std.fmt.parseInt(i32, input, 10) catch
                return error.InvalidFormat,
        };
    }

    /// So it works with the config framework.
    pub fn parseCLI(input: ?[]const u8) !Modifier {
        return try parse(input orelse return error.ValueRequired);
    }

    /// Used by config formatter
    pub fn formatEntry(self: Modifier, formatter: anytype) !void {
        var buf: [1024]u8 = undefined;
        switch (self) {
            .percent => |v| {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "{d}%",
                        .{(v - 1) * 100},
                    ) catch return error.OutOfMemory,
                );
            },

            .absolute => |v| {
                try formatter.formatEntry(
                    []const u8,
                    std.fmt.bufPrint(
                        &buf,
                        "{d}",
                        .{v},
                    ) catch return error.OutOfMemory,
                );
            },
        }
    }

    /// Apply a modifier to a numeric value.
    pub fn apply(self: Modifier, v: anytype) @TypeOf(v) {
        const T = @TypeOf(v);
        const Tinfo = @typeInfo(T);
        return switch (comptime Tinfo) {
            .int, .comptime_int => switch (self) {
                .percent => |p| percent: {
                    const p_clamped: f64 = @max(0, p);
                    const v_f64: f64 = @floatFromInt(v);
                    const applied_f64: f64 = @round(v_f64 * p_clamped);
                    const applied_T: T = @intFromFloat(applied_f64);
                    break :percent applied_T;
                },

                .absolute => |abs| absolute: {
                    const v_i64: i64 = @intCast(v);
                    const abs_i64: i64 = @intCast(abs);
                    const applied_i64: i64 = v_i64 +| abs_i64;
                    const clamped_i64: i64 = if (Tinfo.int.signedness == .signed)
                        applied_i64
                    else
                        @max(0, applied_i64);
                    const applied_T: T = std.math.cast(T, clamped_i64) orelse
                        std.math.maxInt(T) * @as(T, @intCast(std.math.sign(clamped_i64)));
                    break :absolute applied_T;
                },
            },
            .float, .comptime_float => return switch (self) {
                .percent => |p| v * @max(0, p),
                .absolute => |abs| v + @as(T, @floatFromInt(abs)),
            },
            else => {},
        };
    }

    /// Hash using the hasher.
    pub fn hash(self: Modifier, hasher: anytype) void {
        const autoHash = std.hash.autoHash;
        autoHash(hasher, std.meta.activeTag(self));
        switch (self) {
            // floats can't be hashed directly so we bitcast to i64.
            // for the purpose of what we're trying to do this seems
            // good enough but I would prefer value hashing.
            .percent => |v| autoHash(hasher, @as(i64, @bitCast(v))),
            .absolute => |v| autoHash(hasher, v),
        }
    }

    test "formatConfig percent" {
        const configpkg = @import("../config.zig");
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        const p = try parseCLI("24%");
        try p.formatEntry(configpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = 24%\n", buf.written());
    }

    test "formatConfig absolute" {
        const configpkg = @import("../config.zig");
        const testing = std.testing;
        var buf: std.Io.Writer.Allocating = .init(testing.allocator);
        defer buf.deinit();

        const p = try parseCLI("-30");
        try p.formatEntry(configpkg.entryFormatter("a", &buf.writer));
        try std.testing.expectEqualSlices(u8, "a = -30\n", buf.written());
    }
};

/// Key is an enum of all the available metrics keys.
pub const Key = key: {
    const field_infos = std.meta.fields(Metrics);
    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var count: usize = 0;
    for (field_infos, 0..) |field, i| {
        if (field.type != u32 and field.type != i32 and field.type != f64) continue;
        enumFields[i] = .{ .name = field.name, .value = i };
        count += 1;
    }

    var decls = [_]std.builtin.Type.Declaration{};
    break :key @Type(.{
        .@"enum" = .{
            .tag_type = std.math.IntFittingRange(0, count - 1),
            .fields = enumFields[0..count],
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
};

// NOTE: This is purposely not pub because we want to force outside callers
// to use the `.{}` syntax so unused fields are detected by the compiler.
fn init() Metrics {
    return .{
        .cell_width = 0,
        .cell_height = 0,
        .cell_baseline = 0,
        .underline_position = 0,
        .underline_thickness = 0,
        .strikethrough_position = 0,
        .strikethrough_thickness = 0,
        .overline_position = 0,
        .overline_thickness = 0,
        .box_thickness = 0,
        .cursor_height = 0,
        .icon_height = 0.0,
        .face_width = 0.0,
        .face_height = 0.0,
        .face_y = 0.0,
    };
}

test "Metrics: apply modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_width, .{ .percent = 1.2 });

    var m: Metrics = init();
    m.cell_width = 100;
    m.apply(set);
    try testing.expectEqual(@as(u32, 120), m.cell_width);
}

test "Metrics: adjust cell height smaller" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    // We choose numbers such that the subtracted number of pixels is odd,
    // as that's the case that could most easily have off-by-one errors.
    // Here we're removing 25 pixels: 12 on the bottom, 13 on top.
    try set.put(alloc, .cell_height, .{ .percent = 0.75 });

    var m: Metrics = init();
    m.face_y = 0.33;
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.overline_position = 0;
    m.cell_height = 100;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(-11.67, m.face_y);
    try testing.expectEqual(@as(u32, 75), m.cell_height);
    try testing.expectEqual(@as(u32, 38), m.cell_baseline);
    try testing.expectEqual(@as(u32, 42), m.underline_position);
    try testing.expectEqual(@as(u32, 17), m.strikethrough_position);
    try testing.expectEqual(@as(i32, -13), m.overline_position);
    // Cursor height is separate from cell height and does not follow it.
    try testing.expectEqual(@as(u32, 100), m.cursor_height);
}

test "Metrics: adjust cell height larger" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    // We choose numbers such that the added number of pixels is odd,
    // as that's the case that could most easily have off-by-one errors.
    // Here we're adding 75 pixels: 37 on the bottom, 38 on top.
    try set.put(alloc, .cell_height, .{ .percent = 1.75 });

    var m: Metrics = init();
    m.face_y = 0.33;
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.overline_position = 0;
    m.cell_height = 100;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(37.33, m.face_y);
    try testing.expectEqual(@as(u32, 175), m.cell_height);
    try testing.expectEqual(@as(u32, 87), m.cell_baseline);
    try testing.expectEqual(@as(u32, 93), m.underline_position);
    try testing.expectEqual(@as(u32, 68), m.strikethrough_position);
    try testing.expectEqual(@as(i32, 38), m.overline_position);
    // Cursor height is separate from cell height and does not follow it.
    try testing.expectEqual(@as(u32, 100), m.cursor_height);
}

test "Modifier: parse absolute" {
    const testing = std.testing;

    {
        const m = try Modifier.parse("100");
        try testing.expectEqual(Modifier{ .absolute = 100 }, m);
    }

    {
        const m = try Modifier.parse("-100");
        try testing.expectEqual(Modifier{ .absolute = -100 }, m);
    }
}

test "Modifier: parse percent" {
    const testing = std.testing;

    {
        const m = try Modifier.parse("20%");
        try testing.expectEqual(Modifier{ .percent = 1.2 }, m);
    }
    {
        const m = try Modifier.parse("-20%");
        try testing.expectEqual(Modifier{ .percent = 0.8 }, m);
    }
    {
        const m = try Modifier.parse("0%");
        try testing.expectEqual(Modifier{ .percent = 1 }, m);
    }
}

test "Modifier: percent" {
    const testing = std.testing;

    {
        const m: Modifier = .{ .percent = 0.8 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 80), v);
    }
    {
        const m: Modifier = .{ .percent = 1.8 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 180), v);
    }
}

test "Modifier: absolute" {
    const testing = std.testing;

    {
        const m: Modifier = .{ .absolute = -100 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = -120 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = 100 };
        const v: u32 = m.apply(@as(u32, 100));
        try testing.expectEqual(@as(u32, 200), v);
    }
}
