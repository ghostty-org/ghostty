const std = @import("std");
const builtin = @import("builtin");
const options = @import("main.zig").options;
pub const Metrics = @import("face/Metrics.zig");
const freetype = @import("face/freetype.zig");
const coretext = @import("face/coretext.zig");
pub const web_canvas = @import("face/web_canvas.zig");

/// Face implementation for the compile options.
pub const Face = switch (options.backend) {
    .freetype,
    .fontconfig_freetype,
    .coretext_freetype,
    => freetype.Face,

    .coretext => coretext.Face,
    .web_canvas => web_canvas.Face,
};

/// If a DPI can't be calculated, this DPI is used. This is probably
/// wrong on modern devices so it is highly recommended you get the DPI
/// using whatever platform method you can.
pub const default_dpi = if (builtin.os.tag == .macos) 72 else 96;

/// Options for initializing a font face.
pub const Options = struct {
    size: DesiredSize,
    metric_modifiers: ?*const Metrics.ModifierSet = null,
};

/// The desired size for loading a font.
pub const DesiredSize = struct {
    // Desired size in points
    points: u16,

    // The DPI of the screen so we can convert points to pixels.
    xdpi: u16 = default_dpi,
    ydpi: u16 = default_dpi,

    // Converts points to pixels
    pub fn pixels(self: DesiredSize) u16 {
        // 1 point = 1/72 inch
        return (self.points * self.ydpi) / 72;
    }
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
    /// The maximum height of the glyph. If this is set, then any glyph
    /// larger than this height will be shrunk to this height. The scaling
    /// is typically naive, but ultimately up to the rasterizer.
    max_height: ?u16 = null,

    /// The number of grid cells this glyph will take up. This can be used
    /// optionally by the rasterizer to better layout the glyph.
    cell_width: ?u2 = null,

    /// Thicken the glyph. This draws the glyph with a thicker stroke width.
    /// This is purely an aesthetic setting.
    ///
    /// This only works with CoreText currently.
    thicken: bool = false,
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
