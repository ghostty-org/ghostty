//! This implements the built-in "sprite face". This font renders
//! the built-in glyphs for the terminal, such as box drawing fonts, as well
//! as specific sprites that are part of our rendering model such as
//! text decorations (underlines).
//!
//! This isn't really a "font face" so much as it is quacks like a font
//! face with regards to how it works with font.Group. We don't use any
//! dynamic dispatch so it isn't truly an interface but the functions
//! and behaviors are close enough to a system face that it makes it easy
//! to integrate with font.Group. This is desirable so that higher level
//! processes such as GroupCache, Shaper, etc. don't need to be aware of
//! special sprite handling and just treat it like a normal font face.
const Face = @This();

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;
const Box = @import("Box.zig");
const underline = @import("underline.zig");

const log = std.log.scoped(.font_sprite);

/// The cell width and height.
width: u32,
height: u32,

/// Base thickness value for lines of sprites. This is in pixels. If you
/// want to do any DPI scaling, it is expected to be done earlier.
thickness: u32,

/// The position fo the underline.
underline_position: u32 = 0,

/// Returns true if the codepoint exists in our sprite font.
pub fn hasCodepoint(self: Face, cp: u32, p: ?font.Presentation) bool {
    // We ignore presentation. No matter what presentation is requested
    // we always provide glyphs for our codepoints.
    _ = p;
    _ = self;
    return Kind.init(cp) != null;
}

/// Render the glyph.
pub fn renderGlyph(
    self: Face,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    if (std.debug.runtime_safety) {
        if (!self.hasCodepoint(cp, null)) {
            log.err("invalid codepoint cp={x}", .{cp});
            unreachable; // crash
        }
    }

    // Safe to ".?" because of the above assertion.
    return switch (Kind.init(cp).?) {
        .box => box: {
            const f: Box = .{
                .width = self.width,
                .height = self.height,
                .thickness = self.thickness,
            };

            break :box try f.renderGlyph(alloc, atlas, cp);
        },

        .underline => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            self.width,
            self.height,
            self.underline_position,
            self.thickness,
        ),
    };
}

/// Kind of sprites we have. Drawing is implemented separately for each kind.
const Kind = enum {
    box,
    underline,

    pub fn init(cp: u32) ?Kind {
        return switch (cp) {
            Sprite.start...Sprite.end => switch (@as(Sprite, @enumFromInt(cp))) {
                .underline,
                .underline_double,
                .underline_dotted,
                .underline_dashed,
                .underline_curly,
                => .underline,

                .cursor_rect,
                .cursor_hollow_rect,
                .cursor_bar,
                => .box,
            },

            // Box fonts
            0x2500...0x257F, // "Box Drawing" block
            0x2580...0x259F, // "Block Elements" block
            0x2800...0x28FF, // "Braille" block
            0x1FB00...0x1FB3B, // "Symbols for Legacy Computing" block
            0x1FB3C...0x1FB40,
            0x1FB47...0x1FB4B,
            0x1FB57...0x1FB5B,
            0x1FB62...0x1FB66,
            0x1FB6C...0x1FB6F,
            0x1FB41...0x1FB45,
            0x1FB4C...0x1FB50,
            0x1FB52...0x1FB56,
            0x1FB5D...0x1FB61,
            0x1FB68...0x1FB6B,
            0x1FB70...0x1FB8B,
            0x1FB46,
            0x1FB51,
            0x1FB5C,
            0x1FB67,
            0x1FB9A,
            0x1FB9B,
            => .box,

            else => null,
        };
    }
};
