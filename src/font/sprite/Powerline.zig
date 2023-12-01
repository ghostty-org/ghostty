//! This file contains functions for drawing certain characters from Powerline
//! Extra (https://github.com/ryanoasis/powerline-extra-symbols). These
//! characters are similarly to box-drawing characters (see Box.zig), so the
//! logic will be mainly the same, just with a much reduced character set.
//!
//! Note that this is not the complete list of Powerline glyphs that may be
//! needed, so this may grow to add other glyphs from the set.
const Powerline = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const font = @import("../main.zig");

const log = std.log.scoped(.powerline_font);

/// The cell width and height because the boxes are fit perfectly
/// into a cell so that they all properly connect with zero spacing.
width: u32,
height: u32,

/// Base thickness value for glyphs that are not completely solid (backslashes,
/// thin half-circles, etc). If you want to do any DPI scaling, it is expected
/// to be done earlier.
///
/// TODO: this and Thickness are currently unused but will be when the
/// aforementioned glyphs are added.
thickness: u32,

/// The thickness of a line.
const Thickness = enum {
    super_light,
    light,
    heavy,

    /// Calculate the real height of a line based on its thickness
    /// and a base thickness value. The base thickness value is expected
    /// to be in pixels.
    fn height(self: Thickness, base: u32) u32 {
        return switch (self) {
            .super_light => @max(base / 2, 1),
            .light => base,
            .heavy => base * 2,
        };
    }
};

pub fn renderGlyph(
    self: Powerline,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw
    var canvas = try font.sprite.Canvas.init(alloc, self.width, self.height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    try self.draw(&canvas, cp);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @as(i32, @intCast(self.height));

    return font.Glyph{
        .width = self.width,
        .height = self.height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(self.width),
    };
}

fn draw(self: Powerline, canvas: *font.sprite.Canvas, cp: u32) !void {
    switch (cp) {
        // Hard dividers and triangles
        0xE0B0,
        0xE0B2,
        0xE0B8,
        0xE0BA,
        0xE0BC,
        0xE0BE,
        => try self.draw_wedge_triangle(canvas, cp),

        else => return error.InvalidCodepoint,
    }
}

fn draw_wedge_triangle(self: Powerline, canvas: *font.sprite.Canvas, cp: u32) !void {
    const width = self.width;
    const height = self.height;

    var p1_x: u32 = 0;
    var p2_x: u32 = 0;
    var p3_x: u32 = 0;
    var p1_y: u32 = 0;
    var p2_y: u32 = 0;
    var p3_y: u32 = 0;

    switch (cp) {
        0xE0B0 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = height / 2;
            p3_x = 0;
            p3_y = height;
        },

        0xE0B2 => {
            p1_x = width;
            p1_y = 0;
            p2_x = 0;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },

        0xE0B8 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = height;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BA => {
            p1_x = width;
            p1_y = 0;
            p2_x = width;
            p2_y = height;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BC => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = 0;
            p3_x = 0;
            p3_y = height;
        },

        0xE0BE => {
            p1_x = 0;
            p1_y = 0;
            p2_x = width;
            p2_y = 0;
            p3_x = width;
            p3_y = height;
        },

        else => unreachable,
    }

    canvas.triangle(.{
        .p1 = .{ .x = @as(i32, @intCast(p1_x)), .y = @as(i32, @intCast(p1_y)) },
        .p2 = .{ .x = @as(i32, @intCast(p2_x)), .y = @as(i32, @intCast(p2_y)) },
        .p3 = .{ .x = @as(i32, @intCast(p3_x)), .y = @as(i32, @intCast(p3_y)) },
    }, .on);
}

test "all" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const cps = [_]u32{
        0xE0B0,
        0xE0B2,
        0xE0B8,
        0xE0BA,
        0xE0BC,
        0xE0BE,
    };
    for (cps) |cp| {
        var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
        defer atlas_greyscale.deinit(alloc);

        const face: Powerline = .{ .width = 18, .height = 36, .thickness = 2 };
        const glyph = try face.renderGlyph(
            alloc,
            &atlas_greyscale,
            cp,
        );
        try testing.expectEqual(@as(u32, face.width), glyph.width);
        try testing.expectEqual(@as(u32, face.height), glyph.height);
    }
}
