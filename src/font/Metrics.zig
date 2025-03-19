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

/// Original cell width in pixels. This is used to keep
/// glyphs centered if the cell width is adjusted wider.
original_cell_width: ?u32 = null,

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
};

/// Metrics extracted from a font face, based on
/// the metadata tables and glyph measurements.
pub const FaceMetrics = struct {
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
    const cell_width = @ceil(face.cell_width);
    const cell_height = @ceil(face.ascent - face.descent + face.line_gap);

    // We split our line gap in two parts, and put half of it on the top
    // of the cell and the other half on the bottom, so that our text never
    // bumps up against either edge of the cell vertically.
    const half_line_gap = face.line_gap / 2;

    // Unlike all our other metrics, `cell_baseline` is relative to the
    // BOTTOM of the cell.
    const cell_baseline = @round(half_line_gap - face.descent);

    // We calculate a top_to_baseline to make following calculations simpler.
    const top_to_baseline = cell_height - cell_baseline;

    // If we don't have a provided cap height,
    // we estimate it as 75% of the ascent.
    const cap_height = face.cap_height orelse face.ascent * 0.75;

    // If we don't have a provided ex height,
    // we estimate it as 75% of the cap height.
    const ex_height = face.ex_height orelse cap_height * 0.75;

    // If we don't have a provided underline thickness,
    // we estimate it as 15% of the ex height.
    const underline_thickness = @max(1, @ceil(face.underline_thickness orelse 0.15 * ex_height));

    // If we don't have a provided strikethrough thickness
    // then we just use the underline thickness for it.
    const strikethrough_thickness = @max(1, @ceil(face.strikethrough_thickness orelse underline_thickness));

    // If we don't have a provided underline position then
    // we place it 1 underline-thickness below the baseline.
    const underline_position = @round(top_to_baseline -
        (face.underline_position orelse
            -underline_thickness));

    // If we don't have a provided strikethrough position
    // then we center the strikethrough stroke at half the
    // ex height, so that it's perfectly centered on lower
    // case text.
    const strikethrough_position = @round(top_to_baseline -
        (face.strikethrough_position orelse
            ex_height * 0.5 + strikethrough_thickness * 0.5));

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

                // Preserve the original cell width if not set.
                if (self.original_cell_width == null) {
                    self.original_cell_width = self.cell_width;
                }

                // Set the new value
                @field(self, @tagName(tag)) = new;

                // For cell height, we have to also modify some positions
                // that are absolute from the top of the cell. The main goal
                // here is to center the baseline so that text is vertically
                // centered in the cell.
                if (comptime tag == .cell_height) {
                    // We split the difference in half because we want to
                    // center the baseline in the cell.
                    if (new > original) {
                        const diff = (new - original) / 2;
                        self.cell_baseline +|= diff;
                        self.underline_position +|= diff;
                        self.strikethrough_position +|= diff;
                    } else {
                        const diff = (original - new) / 2;
                        self.cell_baseline -|= diff;
                        self.underline_position -|= diff;
                        self.strikethrough_position -|= diff;
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
        const signed = @typeInfo(T).int.signedness == .signed;
        return switch (self) {
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
                const clamped_i64: i64 = if (signed) applied_i64 else @max(0, applied_i64);
                const applied_T: T = std.math.cast(T, clamped_i64) orelse
                    std.math.maxInt(T) * @as(T, @intCast(std.math.sign(clamped_i64)));
                break :absolute applied_T;
            },
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
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        const p = try parseCLI("24%");
        try p.formatEntry(configpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = 24%\n", buf.items);
    }

    test "formatConfig absolute" {
        const configpkg = @import("../config.zig");
        const testing = std.testing;
        var buf = std.ArrayList(u8).init(testing.allocator);
        defer buf.deinit();

        const p = try parseCLI("-30");
        try p.formatEntry(configpkg.entryFormatter("a", buf.writer()));
        try std.testing.expectEqualSlices(u8, "a = -30\n", buf.items);
    }
};

/// Key is an enum of all the available metrics keys.
pub const Key = key: {
    const field_infos = std.meta.fields(Metrics);
    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    var count: usize = 0;
    for (field_infos, 0..) |field, i| {
        if (field.type != u32 and field.type != i32) continue;
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
    try set.put(alloc, .cell_height, .{ .percent = 0.5 });

    var m: Metrics = init();
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.cell_height = 100;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(@as(u32, 50), m.cell_height);
    try testing.expectEqual(@as(u32, 25), m.cell_baseline);
    try testing.expectEqual(@as(u32, 30), m.underline_position);
    try testing.expectEqual(@as(u32, 5), m.strikethrough_position);
    // Cursor height is separate from cell height and does not follow it.
    try testing.expectEqual(@as(u32, 100), m.cursor_height);
}

test "Metrics: adjust cell height larger" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_height, .{ .percent = 2 });

    var m: Metrics = init();
    m.cell_baseline = 50;
    m.underline_position = 55;
    m.strikethrough_position = 30;
    m.cell_height = 100;
    m.cursor_height = 100;
    m.apply(set);
    try testing.expectEqual(@as(u32, 200), m.cell_height);
    try testing.expectEqual(@as(u32, 100), m.cell_baseline);
    try testing.expectEqual(@as(u32, 105), m.underline_position);
    try testing.expectEqual(@as(u32, 80), m.strikethrough_position);
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
