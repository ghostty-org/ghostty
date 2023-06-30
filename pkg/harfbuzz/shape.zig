const std = @import("std");
const c = @import("c.zig");
const Font = @import("font.zig").Font;
const Buffer = @import("buffer.zig").Buffer;
const Feature = @import("common.zig").Feature;

/// Shapes buffer using font turning its Unicode characters content to
/// positioned glyphs. If features is not NULL, it will be used to control
/// the features applied during shaping. If two features have the same tag
/// but overlapping ranges the value of the feature with the higher index
/// takes precedence.
pub fn shape(font: Font, buf: Buffer, features: ?[]const Feature) void {
    const hb_feats: [*c]const c.hb_feature_t = feats: {
        if (features) |fs| {
            if (fs.len > 0) break :feats @ptrCast(fs.ptr);
        }

        break :feats null;
    };

    c.hb_shape(
        font.handle,
        buf.handle,
        hb_feats,
        if (features) |f| @intCast(f.len) else 0,
    );
}
