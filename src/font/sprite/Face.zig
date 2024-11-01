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
const Powerline = @import("Powerline.zig");
const underline = @import("underline.zig");

const log = std.log.scoped(.font_sprite);

/// The cell width and height.
width: u32,
height: u32,

/// Base thickness value for lines of sprites. This is in pixels. If you
/// want to do any DPI scaling, it is expected to be done earlier.
thickness: u32 = 1,

/// The position of the underline.
underline_position: u32 = 0,

/// The position of the strikethrough.
// NOTE(mitchellh): We don't use a dedicated strikethrough thickness
// setting yet but fonts can in theory set this. If this becomes an
// issue in practice we can add it here.
strikethrough_position: u32 = 0,

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
    opts: font.face.RenderOptions,
) !font.Glyph {
    if (std.debug.runtime_safety) {
        if (!self.hasCodepoint(cp, null)) {
            log.err("invalid codepoint cp={x}", .{cp});
            unreachable; // crash
        }
    }

    // We adjust our sprite width based on the cell width.
    const width = switch (opts.cell_width orelse 1) {
        0, 1 => self.width,
        else => |width| self.width * width,
    };

    // It should be impossible for this to be null and we assert that
    // in runtime safety modes but in case it is its not worth memory
    // corruption so we return a valid, blank glyph.
    const kind = Kind.init(cp) orelse return .{
        .width = 0,
        .height = 0,
        .offset_x = 0,
        .offset_y = 0,
        .atlas_x = 0,
        .atlas_y = 0,
        .advance_x = 0,
    };

    // Safe to ".?" because of the above assertion.
    return switch (kind) {
        .box => box: {
            const thickness = switch (cp) {
                @intFromEnum(Sprite.cursor_rect),
                @intFromEnum(Sprite.cursor_hollow_rect),
                @intFromEnum(Sprite.cursor_bar),
                => if (opts.grid_metrics) |m| m.cursor_thickness else self.thickness,
                else => self.thickness,
            };

            const f: Box, const y_offset: u32 = face: {
                // Expected, usual values.
                var f: Box = .{
                    .width = width,
                    .height = self.height,
                    .thickness = thickness,
                };

                // If the codepoint is unadjusted then we want to adjust
                // (heh) the width/height to the proper size and also record
                // an offset to apply to our final glyph so it renders in the
                // correct place because renderGlyph assumes full size.
                var y_offset: u32 = 0;
                if (Box.unadjustedCodepoint(cp)) unadjust: {
                    const metrics = opts.grid_metrics orelse break :unadjust;
                    const height = metrics.original_cell_height orelse break :unadjust;

                    // If our height shrunk, then we use the original adjusted
                    // height because we don't want to overflow the cell.
                    if (height >= self.height) break :unadjust;

                    // The offset is divided by two because it is vertically
                    // centered.
                    y_offset = (self.height - height) / 2;
                    f.height = height;
                }

                break :face .{ f, y_offset };
            };

            var g = try f.renderGlyph(alloc, atlas, cp);
            g.offset_y += @intCast(y_offset);
            break :box g;
        },

        .underline => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            width,
            self.height,
            self.underline_position,
            self.thickness,
        ),

        .strikethrough => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            width,
            self.height,
            self.strikethrough_position,
            self.thickness,
        ),

        .overline => try underline.renderGlyph(
            alloc,
            atlas,
            @enumFromInt(cp),
            width,
            self.height,
            0,
            self.thickness,
        ),

        .powerline => powerline: {
            const f: Powerline = .{
                .width = width,
                .height = self.height,
                .thickness = self.thickness,
            };

            break :powerline try f.renderGlyph(alloc, atlas, cp);
        },
    };
}

/// Kind of sprites we have. Drawing is implemented separately for each kind.
const Kind = enum {
    box,
    underline,
    overline,
    strikethrough,
    powerline,

    pub fn init(cp: u32) ?Kind {
        return switch (cp) {
            Sprite.start...Sprite.end => switch (@as(Sprite, @enumFromInt(cp))) {
                .underline,
                .underline_double,
                .underline_dotted,
                .underline_dashed,
                .underline_curly,
                => .underline,

                .overline,
                => .overline,

                .strikethrough,
                => .strikethrough,

                .cursor_rect,
                .cursor_hollow_rect,
                .cursor_bar,
                => .box,
            },

            // == Box fonts ==

            // "Box Drawing" block
            // ─ ━ │ ┃ ┄ ┅ ┆ ┇ ┈ ┉ ┊ ┋ ┌ ┍ ┎ ┏ ┐ ┑ ┒ ┓ └ ┕ ┖ ┗ ┘ ┙ ┚ ┛ ├ ┝ ┞ ┟ ┠
            // ┡ ┢ ┣ ┤ ┥ ┦ ┧ ┨ ┩ ┪ ┫ ┬ ┭ ┮ ┯ ┰ ┱ ┲ ┳ ┴ ┵ ┶ ┷ ┸ ┹ ┺ ┻ ┼ ┽ ┾ ┿ ╀ ╁
            // ╂ ╃ ╄ ╅ ╆ ╇ ╈ ╉ ╊ ╋ ╌ ╍ ╎ ╏ ═ ║ ╒ ╓ ╔ ╕ ╖ ╗ ╘ ╙ ╚ ╛ ╜ ╝ ╞ ╟ ╠ ╡ ╢
            // ╣ ╤ ╥ ╦ ╧ ╨ ╩ ╪ ╫ ╬ ╭ ╮ ╯ ╰ ╱ ╲ ╳ ╴ ╵ ╶ ╷ ╸ ╹ ╺ ╻ ╼ ╽ ╾ ╿
            0x2500...0x257F,

            // "Block Elements" block
            // ▀ ▁ ▂ ▃ ▄ ▅ ▆ ▇ █ ▉ ▊ ▋ ▌ ▍ ▎ ▏ ▐ ░ ▒ ▓ ▔ ▕ ▖ ▗ ▘ ▙ ▚ ▛ ▜ ▝ ▞ ▟
            0x2580...0x259F,

            // "Braille" block
            0x2800...0x28FF,

            // "Symbols for Legacy Computing" block
            // (Block Mosaics / "Sextants")
            // 🬀 🬁 🬂 🬃 🬄 🬅 🬆 🬇 🬈 🬉 🬊 🬋 🬌 🬍 🬎 🬏 🬐 🬑 🬒 🬓 🬔 🬕 🬖 🬗 🬘 🬙 🬚 🬛 🬜 🬝 🬞 🬟 🬠
            // 🬡 🬢 🬣 🬤 🬥 🬦 🬧 🬨 🬩 🬪 🬫 🬬 🬭 🬮 🬯 🬰 🬱 🬲 🬳 🬴 🬵 🬶 🬷 🬸 🬹 🬺 🬻
            // (Smooth Mosaics)
            // 🬼 🬽 🬾 🬿 🭀 🭁 🭂 🭃 🭄 🭅 🭆
            // 🭇 🭈 🭉 🭊 🭋 🭌 🭍 🭎 🭏 🭐 🭑
            // 🭒 🭓 🭔 🭕 🭖 🭗 🭘 🭙 🭚 🭛 🭜
            // 🭝 🭞 🭟 🭠 🭡 🭢 🭣 🭤 🭥 🭦 🭧
            // 🭨 🭩 🭪 🭫 🭬 🭭 🭮 🭯
            // (Block Elements)
            // 🭰 🭱 🭲 🭳 🭴 🭵 🭶 🭷 🭸 🭹 🭺 🭻
            // 🭼 🭽 🭾 🭿 🮀 🮁
            // 🮂 🮃 🮄 🮅 🮆
            // 🮇 🮈 🮉 🮊 🮋
            // (Rectangular Shade Characters)
            // 🮌 🮍 🮎 🮏 🮐 🮑 🮒
            0x1FB00...0x1FB92,
            // (Rectangular Shade Characters)
            // 🮔
            // (Fill Characters)
            // 🮕 🮖 🮗
            // (Diagonal Fill Characters)
            // 🮘 🮙
            // (Smooth Mosaics)
            // 🮚 🮛
            // (Triangular Shade Characters)
            // 🮜 🮝 🮞 🮟
            // (Character Cell Diagonals)
            // 🮠 🮡 🮢 🮣 🮤 🮥 🮦 🮧 🮨 🮩 🮪 🮫 🮬 🮭 🮮
            // (Light Solid Line With Stroke)
            // 🮯
            0x1FB94...0x1FBAF,
            // (Negative Terminal Characters)
            // 🮽 🮾 🮿
            0x1FBBD...0x1FBBF,
            // (Block Elements)
            // 🯎 🯏
            // (Character Cell Diagonals)
            // 🯐 🯑 🯒 🯓 🯔 🯕 🯖 🯗 🯘 🯙 🯚 🯛 🯜 🯝 🯞 🯟
            // (Geometric Shapes)
            // 🯠 🯡 🯢 🯣 🯤 🯥 🯦 🯧 🯨 🯩 🯪 🯫 🯬 🯭 🯮 🯯
            0x1FBCE...0x1FBEF,
            => .box,

            // Powerline fonts
            0xE0B0,
            0xE0B4,
            0xE0B6,
            0xE0B2,
            0xE0B8,
            0xE0BA,
            0xE0BC,
            0xE0BE,
            0xE0D2,
            0xE0D4,
            => .powerline,

            // (Git Branch)
            //          
            //                    
            //                    
            //            
            0xF5D0...0xF60D => .box,

            else => null,
        };
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
