const std = @import("std");
const builtin = @import("builtin");
const build_config = @import("../build_config.zig");

const library = @import("library.zig");

pub const Atlas = @import("Atlas.zig");
pub const Backend = @import("backend.zig").Backend;
pub const discovery = @import("discovery.zig");
pub const embedded = @import("embedded.zig");
pub const face = @import("face.zig");
pub const CodepointMap = @import("CodepointMap.zig");
pub const CodepointResolver = @import("CodepointResolver.zig");
pub const Collection = @import("Collection.zig");
pub const DeferredFace = @import("DeferredFace.zig");
pub const Face = face.Face;
pub const Glyph = @import("Glyph.zig");
pub const Metrics = @import("Metrics.zig");
pub const opentype = @import("opentype.zig");
pub const shape = @import("shape.zig");
pub const Shaper = shape.Shaper;
pub const ShaperCache = shape.Cache;
pub const SharedGrid = @import("SharedGrid.zig");
pub const SharedGridSet = @import("SharedGridSet.zig");
pub const sprite = @import("sprite.zig");
pub const Sprite = sprite.Sprite;
pub const SpriteFace = sprite.Face;
pub const Descriptor = discovery.Descriptor;
pub const Discover = discovery.Discover;
pub const Library = library.Library;

// If we're targeting wasm then we export some wasm APIs.
comptime {
    if (builtin.target.cpu.arch.isWasm()) {
        _ = Atlas.Wasm;
        _ = DeferredFace.Wasm;
        _ = face.web_canvas.Wasm;
        _ = shape.web_canvas.Wasm;
    }
}

/// Build options
pub const options: struct {
    backend: Backend,
} = .{
    // TODO: we need to modify the build config for wasm builds. the issue
    // is we're sharing the build config options between all exes in build.zig.
    // We need to construct it per target.
    .backend = if (builtin.target.cpu.arch.isWasm()) .web_canvas else build_config.font_backend,
};

/// The styles that a family can take.
pub const Style = enum(u3) {
    regular = 0,
    bold = 1,
    italic = 2,
    bold_italic = 3,
};

/// The presentation for an emoji.
pub const Presentation = enum(u1) {
    text = 0, // U+FE0E
    emoji = 1, // U+FEOF
};

/// A FontIndex that can be used to use the sprite font directly.
pub const sprite_index = Collection.Index.initSpecial(.sprite);

/// The default font size adjustment we use when loading fallback fonts.
///
/// TODO: Add user configuration for this instead of hard-coding it.
pub const default_fallback_adjustment: Collection.SizeAdjustment = .ic_width;

test {
    // For non-wasm we want to test everything we can
    if (!comptime builtin.target.cpu.arch.isWasm()) {
        @import("std").testing.refAllDecls(@This());
        return;
    }

    _ = Atlas;
}
