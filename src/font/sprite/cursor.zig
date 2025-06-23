//! This file renders cursor sprites.
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const font = @import("../main.zig");
const Sprite = font.sprite.Sprite;

/// Draw a cursor.
pub fn renderGlyph(
    alloc: Allocator,
    atlas: *font.Atlas,
    sprite: Sprite,
    width: u32,
    height: u32,
    thickness: u32,
) !font.Glyph {
    // Make a canvas of the desired size
    var canvas = try font.sprite.Canvas.init(alloc, width, height);
    defer canvas.deinit();

    // Draw the appropriate sprite
    switch (sprite) {
        Sprite.cursor_rect => canvas.rect(.{
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
        }, .on),
        Sprite.cursor_hollow_rect => {
            // left
            canvas.rect(.{ .x = 0, .y = 0, .width = thickness, .height = height }, .on);
            // right
            canvas.rect(.{ .x = width -| thickness, .y = 0, .width = thickness, .height = height }, .on);
            // top
            canvas.rect(.{ .x = 0, .y = 0, .width = width, .height = thickness }, .on);
            // bottom
            canvas.rect(.{ .x = 0, .y = height -| thickness, .width = width, .height = thickness }, .on);
        },
        Sprite.cursor_bar => canvas.rect(.{
            .x = 0,
            .y = 0,
            .width = thickness,
            .height = height,
        }, .on),
        else => unreachable,
    }

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    return font.Glyph{
        // HACK: Set the width for the bar cursor to just the thickness,
        //       this is just for the benefit of the custom shader cursor
        //       uniform code. -- In the future code will be introduced to
        //       auto-crop the canvas so that this isn't needed.
        .width = if (sprite == .cursor_bar) thickness else width,
        .height = height,
        .offset_x = 0,
        .offset_y = @intCast(height),
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(width),
    };
}
