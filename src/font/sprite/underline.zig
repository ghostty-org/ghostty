//! This file renders underline sprites. To draw underlines, we render the
//! full cell-width as a sprite and then draw it as a separate pass to the
//! text.
//!
//! We used to render the underlines directly in the GPU shaders but its
//! annoying to support multiple types of underlines and its also annoying
//! to maintain and debug another set of shaders for each renderer instead of
//! just relying on the glyph system we already need to support for text
//! anyways.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;

/// Draw an underline.
pub fn renderGlyph(
    alloc: Allocator,
    atlas: *font.Atlas,
    sprite: Sprite,
    width: u32,
    height: u32,
    line_pos: u32,
    line_thickness: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw. We draw the underline in
    // a full cell size and position it according to "pos".
    var canvas = try font.sprite.Canvas.init(alloc, width, height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    (Draw{
        .width = width,
        .height = height,
        .pos = line_pos,
        .thickness = line_thickness,
    }).draw(&canvas, sprite);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @as(i32, @intCast(height));

    return font.Glyph{
        .width = width,
        .height = height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(width),
    };
}

/// Stores drawing state.
const Draw = struct {
    width: u32,
    height: u32,
    pos: u32,
    thickness: u32,

    /// Draw a specific underline sprite to the canvas.
    fn draw(self: Draw, canvas: *font.sprite.Canvas, sprite: Sprite) void {
        switch (sprite) {
            .underline => self.drawSingle(canvas),
            .underline_double => self.drawDouble(canvas),
            .underline_dotted => self.drawDotted(canvas),
            .underline_dashed => self.drawDashed(canvas),
            .underline_curly => self.drawCurly(canvas),
            else => unreachable,
        }
    }

    /// Draw a single underline.
    fn drawSingle(self: Draw, canvas: *font.sprite.Canvas) void {
        // Ensure we never overflow out of bounds on the canvas
        const y_max = self.height -| 1;
        const bottom = @min(self.pos + self.thickness, y_max);
        const y = @as(i32, @intCast(bottom - self.thickness));

        canvas.rect(.{
            .x = 0,
            .y = y,
            .width = self.width,
            .height = self.thickness,
        }, .on);
    }

    /// Draw a double underline.
    fn drawDouble(self: Draw, canvas: *font.sprite.Canvas) void {
        // The maximum y value has to have space for the bottom underline.
        // If we underflow (saturated) to 0, then we don't draw. This should
        // never happen but we don't want to draw something undefined.
        const y_max = self.height -| 1 -| self.thickness;
        if (y_max == 0) return;

        const space = self.thickness * 2;
        const bottom = @min(self.pos + space, y_max);
        const top = bottom - space;

        canvas.rect(.{
            .x = 0,
            .y = @intCast(top),
            .width = self.width,
            .height = self.thickness,
        }, .on);

        canvas.rect(.{
            .x = 0,
            .y = @intCast(bottom),
            .width = self.width,
            .height = self.thickness,
        }, .on);
    }

    /// Draw a dotted underline.
    fn drawDotted(self: Draw, canvas: *font.sprite.Canvas) void {
        const y_max = self.height -| 1 -| self.thickness;
        if (y_max == 0) return;
        const y = @min(self.pos, y_max);
        const dot_width = @max(self.thickness, 3);
        const dot_count = self.width / dot_width;
        var i: u32 = 0;
        while (i < dot_count) : (i += 2) {
            // Ensure we never go out of bounds for the rect
            const x = @min(i * dot_width, self.width - 1);
            const width = @min(self.width - 1 - x, dot_width);
            canvas.rect(.{
                .x = @intCast(i * dot_width),
                .y = @intCast(y),
                .width = width,
                .height = self.thickness,
            }, .on);
        }
    }

    /// Draw a dashed underline.
    fn drawDashed(self: Draw, canvas: *font.sprite.Canvas) void {
        const y_max = self.height -| 1 -| self.thickness;
        if (y_max == 0) return;
        const y = @min(self.pos, y_max);
        const dash_width = self.width / 3 + 1;
        const dash_count = (self.width / dash_width) + 1;
        var i: u32 = 0;
        while (i < dash_count) : (i += 2) {
            // Ensure we never go out of bounds for the rect
            const x = @min(i * dash_width, self.width - 1);
            const width = @min(self.width - 1 - x, dash_width);
            canvas.rect(.{
                .x = @intCast(x),
                .y = @intCast(y),
                .width = width,
                .height = self.thickness,
            }, .on);
        }
    }

    /// Draw a curly underline. Thanks to Wez Furlong for providing
    /// the basic math structure for this since I was lazy with the
    /// geometry.
    fn drawCurly(self: Draw, canvas: *font.sprite.Canvas) void {
        // This is the lowest that the curl can go.
        const y_max = self.height - 1;

        // Some fonts put the underline too close to the bottom of the
        // cell height and this doesn't allow us to make a high enough
        // wave. This constant is arbitrary, change it for aesthetics.
        const pos = pos: {
            const MIN_HEIGHT = 7;
            const height = y_max - self.pos;
            break :pos if (height < MIN_HEIGHT) self.pos -| MIN_HEIGHT else self.pos;
        };

        // The full heightof the wave can be from the bottom to the
        // underline position. We also calculate our starting y which is
        // slightly below our descender since our wave will move about that.
        const wave_height = @as(f64, @floatFromInt(y_max - pos));
        const half_height = wave_height / 4;
        const y = pos + @as(u32, @intFromFloat(half_height));

        const x_factor = (2 * std.math.pi) / @as(f64, @floatFromInt(self.width));
        var x: u32 = 0;
        while (x < self.width) : (x += 1) {
            const vertical = @as(
                u32,
                @intFromFloat((-1 * half_height) * @sin(@as(f64, @floatFromInt(x)) * x_factor) + half_height),
            );

            var row: u32 = 0;
            while (row < self.thickness) : (row += 1) {
                const y1 = @min(row + y + vertical, y_max);
                canvas.rect(.{
                    .x = @intCast(x),
                    .y = @intCast(y1),
                    .width = 1,
                    .height = 1,
                }, .on);
            }
        }
    }
};

test "single" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    _ = try renderGlyph(
        alloc,
        &atlas_greyscale,
        .underline,
        36,
        18,
        9,
        2,
    );
}

test "curly" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
    defer atlas_greyscale.deinit(alloc);

    _ = try renderGlyph(
        alloc,
        &atlas_greyscale,
        .underline_curly,
        36,
        18,
        9,
        2,
    );
}
