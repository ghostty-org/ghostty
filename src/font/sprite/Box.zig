//! This file contains functions for drawing the box drawing characters
//! (https://en.wikipedia.org/wiki/Box-drawing_character) and related
//! characters that are provided by the terminal.
//!
//! The box drawing logic is based off similar logic in Kitty and Foot.
//! The primary drawing code was ported directly and slightly modified from Foot
//! (https://codeberg.org/dnkl/foot/). Foot is licensed under the MIT
//! license and is copyright 2019 Daniel Eklöf.
//!
//! The modifications made are primarily around spacing, DPI calculations,
//! and adapting the code to our atlas model.
const Box = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const font = @import("../main.zig");
const Sprite = @import("../sprite.zig").Sprite;

const log = std.log.scoped(.box_font);

/// The cell width and height because the boxes are fit perfectly
/// into a cell so that they all properly connect with zero spacing.
width: u32,
height: u32,

/// Base thickness value for lines of the box. This is in pixels. If you
/// want to do any DPI scaling, it is expected to be done earlier.
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
    self: Box,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    // Create the canvas we'll use to draw
    var canvas = try font.sprite.Canvas.init(alloc, self.width, self.height);
    defer canvas.deinit(alloc);

    // Perform the actual drawing
    try self.draw(alloc, &canvas, cp);

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

fn draw(self: Box, alloc: Allocator, canvas: *font.sprite.Canvas, cp: u32) !void {
    switch (cp) {
        0x2500 => self.draw_light_horizontal(canvas),
        0x2501 => self.draw_heavy_horizontal(canvas),
        0x2502 => self.draw_light_vertical(canvas),
        0x2503 => self.draw_heavy_vertical(canvas),
        0x2504 => self.draw_light_triple_dash_horizontal(canvas),
        0x2505 => self.draw_heavy_triple_dash_horizontal(canvas),
        0x2506 => self.draw_light_triple_dash_vertical(canvas),
        0x2507 => self.draw_heavy_triple_dash_vertical(canvas),
        0x2508 => self.draw_light_quadruple_dash_horizontal(canvas),
        0x2509 => self.draw_heavy_quadruple_dash_horizontal(canvas),
        0x250a => self.draw_light_quadruple_dash_vertical(canvas),
        0x250b => self.draw_heavy_quadruple_dash_vertical(canvas),
        0x250c => self.draw_light_down_and_right(canvas),
        0x250d => self.draw_down_light_and_right_heavy(canvas),
        0x250e => self.draw_down_heavy_and_right_light(canvas),
        0x250f => self.draw_heavy_down_and_right(canvas),

        0x2510 => self.draw_light_down_and_left(canvas),
        0x2511 => self.draw_down_light_and_left_heavy(canvas),
        0x2512 => self.draw_down_heavy_and_left_light(canvas),
        0x2513 => self.draw_heavy_down_and_left(canvas),
        0x2514 => self.draw_light_up_and_right(canvas),
        0x2515 => self.draw_up_light_and_right_heavy(canvas),
        0x2516 => self.draw_up_heavy_and_right_light(canvas),
        0x2517 => self.draw_heavy_up_and_right(canvas),
        0x2518 => self.draw_light_up_and_left(canvas),
        0x2519 => self.draw_up_light_and_left_heavy(canvas),
        0x251a => self.draw_up_heavy_and_left_light(canvas),
        0x251b => self.draw_heavy_up_and_left(canvas),
        0x251c => self.draw_light_vertical_and_right(canvas),
        0x251d => self.draw_vertical_light_and_right_heavy(canvas),
        0x251e => self.draw_up_heavy_and_right_down_light(canvas),
        0x251f => self.draw_down_heavy_and_right_up_light(canvas),

        0x2520 => self.draw_vertical_heavy_and_right_light(canvas),
        0x2521 => self.draw_down_light_and_right_up_heavy(canvas),
        0x2522 => self.draw_up_light_and_right_down_heavy(canvas),
        0x2523 => self.draw_heavy_vertical_and_right(canvas),
        0x2524 => self.draw_light_vertical_and_left(canvas),
        0x2525 => self.draw_vertical_light_and_left_heavy(canvas),
        0x2526 => self.draw_up_heavy_and_left_down_light(canvas),
        0x2527 => self.draw_down_heavy_and_left_up_light(canvas),
        0x2528 => self.draw_vertical_heavy_and_left_light(canvas),
        0x2529 => self.draw_down_light_and_left_up_heavy(canvas),
        0x252a => self.draw_up_light_and_left_down_heavy(canvas),
        0x252b => self.draw_heavy_vertical_and_left(canvas),
        0x252c => self.draw_light_down_and_horizontal(canvas),
        0x252d => self.draw_left_heavy_and_right_down_light(canvas),
        0x252e => self.draw_right_heavy_and_left_down_light(canvas),
        0x252f => self.draw_down_light_and_horizontal_heavy(canvas),

        0x2530 => self.draw_down_heavy_and_horizontal_light(canvas),
        0x2531 => self.draw_right_light_and_left_down_heavy(canvas),
        0x2532 => self.draw_left_light_and_right_down_heavy(canvas),
        0x2533 => self.draw_heavy_down_and_horizontal(canvas),
        0x2534 => self.draw_light_up_and_horizontal(canvas),
        0x2535 => self.draw_left_heavy_and_right_up_light(canvas),
        0x2536 => self.draw_right_heavy_and_left_up_light(canvas),
        0x2537 => self.draw_up_light_and_horizontal_heavy(canvas),
        0x2538 => self.draw_up_heavy_and_horizontal_light(canvas),
        0x2539 => self.draw_right_light_and_left_up_heavy(canvas),
        0x253a => self.draw_left_light_and_right_up_heavy(canvas),
        0x253b => self.draw_heavy_up_and_horizontal(canvas),
        0x253c => self.draw_light_vertical_and_horizontal(canvas),
        0x253d => self.draw_left_heavy_and_right_vertical_light(canvas),
        0x253e => self.draw_right_heavy_and_left_vertical_light(canvas),
        0x253f => self.draw_vertical_light_and_horizontal_heavy(canvas),

        0x2540 => self.draw_up_heavy_and_down_horizontal_light(canvas),
        0x2541 => self.draw_down_heavy_and_up_horizontal_light(canvas),
        0x2542 => self.draw_vertical_heavy_and_horizontal_light(canvas),
        0x2543 => self.draw_left_up_heavy_and_right_down_light(canvas),
        0x2544 => self.draw_right_up_heavy_and_left_down_light(canvas),
        0x2545 => self.draw_left_down_heavy_and_right_up_light(canvas),
        0x2546 => self.draw_right_down_heavy_and_left_up_light(canvas),
        0x2547 => self.draw_down_light_and_up_horizontal_heavy(canvas),
        0x2548 => self.draw_up_light_and_down_horizontal_heavy(canvas),
        0x2549 => self.draw_right_light_and_left_vertical_heavy(canvas),
        0x254a => self.draw_left_light_and_right_vertical_heavy(canvas),
        0x254b => self.draw_heavy_vertical_and_horizontal(canvas),
        0x254c => self.draw_light_double_dash_horizontal(canvas),
        0x254d => self.draw_heavy_double_dash_horizontal(canvas),
        0x254e => self.draw_light_double_dash_vertical(canvas),
        0x254f => self.draw_heavy_double_dash_vertical(canvas),

        0x2550 => self.draw_double_horizontal(canvas),
        0x2551 => self.draw_double_vertical(canvas),
        0x2552 => self.draw_down_single_and_right_double(canvas),
        0x2553 => self.draw_down_double_and_right_single(canvas),
        0x2554 => self.draw_double_down_and_right(canvas),
        0x2555 => self.draw_down_single_and_left_double(canvas),
        0x2556 => self.draw_down_double_and_left_single(canvas),
        0x2557 => self.draw_double_down_and_left(canvas),
        0x2558 => self.draw_up_single_and_right_double(canvas),
        0x2559 => self.draw_up_double_and_right_single(canvas),
        0x255a => self.draw_double_up_and_right(canvas),
        0x255b => self.draw_up_single_and_left_double(canvas),
        0x255c => self.draw_up_double_and_left_single(canvas),
        0x255d => self.draw_double_up_and_left(canvas),
        0x255e => self.draw_vertical_single_and_right_double(canvas),
        0x255f => self.draw_vertical_double_and_right_single(canvas),

        0x2560 => self.draw_double_vertical_and_right(canvas),
        0x2561 => self.draw_vertical_single_and_left_double(canvas),
        0x2562 => self.draw_vertical_double_and_left_single(canvas),
        0x2563 => self.draw_double_vertical_and_left(canvas),
        0x2564 => self.draw_down_single_and_horizontal_double(canvas),
        0x2565 => self.draw_down_double_and_horizontal_single(canvas),
        0x2566 => self.draw_double_down_and_horizontal(canvas),
        0x2567 => self.draw_up_single_and_horizontal_double(canvas),
        0x2568 => self.draw_up_double_and_horizontal_single(canvas),
        0x2569 => self.draw_double_up_and_horizontal(canvas),
        0x256a => self.draw_vertical_single_and_horizontal_double(canvas),
        0x256b => self.draw_vertical_double_and_horizontal_single(canvas),
        0x256c => self.draw_double_vertical_and_horizontal(canvas),
        0x256d...0x2570 => try self.draw_light_arc(alloc, canvas, cp),

        0x2571 => self.draw_light_diagonal_upper_right_to_lower_left(canvas),
        0x2572 => self.draw_light_diagonal_upper_left_to_lower_right(canvas),
        0x2573 => self.draw_light_diagonal_cross(canvas),
        0x2574 => self.draw_light_left(canvas),
        0x2575 => self.draw_light_up(canvas),
        0x2576 => self.draw_light_right(canvas),
        0x2577 => self.draw_light_down(canvas),
        0x2578 => self.draw_heavy_left(canvas),
        0x2579 => self.draw_heavy_up(canvas),
        0x257a => self.draw_heavy_right(canvas),
        0x257b => self.draw_heavy_down(canvas),
        0x257c => self.draw_light_left_and_heavy_right(canvas),
        0x257d => self.draw_light_up_and_heavy_down(canvas),
        0x257e => self.draw_heavy_left_and_light_right(canvas),
        0x257f => self.draw_heavy_up_and_light_down(canvas),

        0x2580 => self.draw_upper_half_block(canvas),
        0x2581 => self.draw_lower_one_eighth_block(canvas),
        0x2582 => self.draw_lower_one_quarter_block(canvas),
        0x2583 => self.draw_lower_three_eighths_block(canvas),
        0x2584 => self.draw_lower_half_block(canvas),
        0x2585 => self.draw_lower_five_eighths_block(canvas),
        0x2586 => self.draw_lower_three_quarters_block(canvas),
        0x2587 => self.draw_lower_seven_eighths_block(canvas),
        0x2588 => self.draw_full_block(canvas),
        0x2589 => self.draw_left_seven_eighths_block(canvas),
        0x258a => self.draw_left_three_quarters_block(canvas),
        0x258b => self.draw_left_five_eighths_block(canvas),
        0x258c => self.draw_left_half_block(canvas),
        0x258d => self.draw_left_three_eighths_block(canvas),
        0x258e => self.draw_left_one_quarter_block(canvas),
        0x258f => self.draw_left_one_eighth_block(canvas),

        0x2590 => self.draw_right_half_block(canvas),
        0x2591 => self.draw_light_shade(canvas),
        0x2592 => self.draw_medium_shade(canvas),
        0x2593 => self.draw_dark_shade(canvas),
        0x2594 => self.draw_upper_one_eighth_block(canvas),
        0x2595 => self.draw_right_one_eighth_block(canvas),
        0x2596...0x259f => self.draw_quadrant(canvas, cp),

        0x2800...0x28FF => self.draw_braille(canvas, cp),

        0x1FB00...0x1FB3B => self.draw_sextant(canvas, cp),

        0x1FB3C...0x1FB40,
        0x1FB47...0x1FB4B,
        0x1FB57...0x1FB5B,
        0x1FB62...0x1FB66,
        0x1FB6C...0x1FB6F,
        => try self.draw_wedge_triangle(canvas, cp),

        0x1FB41...0x1FB45,
        0x1FB4C...0x1FB50,
        0x1FB52...0x1FB56,
        0x1FB5D...0x1FB61,
        0x1FB68...0x1FB6B,
        => try self.draw_wedge_triangle_inverted(alloc, canvas, cp),

        0x1FB46,
        0x1FB51,
        0x1FB5C,
        0x1FB67,
        => try self.draw_wedge_triangle_and_box(canvas, cp),

        0x1FB9A => {
            try self.draw_wedge_triangle(canvas, 0x1fb6d);
            try self.draw_wedge_triangle(canvas, 0x1fb6f);
        },

        0x1FB9B => {
            try self.draw_wedge_triangle(canvas, 0x1fb6c);
            try self.draw_wedge_triangle(canvas, 0x1fb6e);
        },

        0x1FB70 => self.draw_vertical_one_eighth_block_n(canvas, 1),
        0x1FB71 => self.draw_vertical_one_eighth_block_n(canvas, 2),
        0x1FB72 => self.draw_vertical_one_eighth_block_n(canvas, 3),
        0x1FB73 => self.draw_vertical_one_eighth_block_n(canvas, 4),
        0x1FB74 => self.draw_vertical_one_eighth_block_n(canvas, 5),
        0x1FB75 => self.draw_vertical_one_eighth_block_n(canvas, 6),

        0x1FB76 => self.draw_horizontal_one_eighth_block_n(canvas, 1),
        0x1FB77 => self.draw_horizontal_one_eighth_block_n(canvas, 2),
        0x1FB78 => self.draw_horizontal_one_eighth_block_n(canvas, 3),
        0x1FB79 => self.draw_horizontal_one_eighth_block_n(canvas, 4),
        0x1FB7A => self.draw_horizontal_one_eighth_block_n(canvas, 5),
        0x1FB7B => self.draw_horizontal_one_eighth_block_n(canvas, 6),

        0x1fb82 => self.draw_upper_one_quarter_block(canvas),
        0x1fb83 => self.draw_upper_three_eighths_block(canvas),
        0x1fb84 => self.draw_upper_five_eighths_block(canvas),
        0x1fb85 => self.draw_upper_three_quarters_block(canvas),
        0x1fb86 => self.draw_upper_seven_eighths_block(canvas),

        0x1fb7c => self.draw_left_and_lower_one_eighth_block(canvas),
        0x1fb7d => self.draw_left_and_upper_one_eighth_block(canvas),
        0x1fb7e => self.draw_right_and_upper_one_eighth_block(canvas),
        0x1fb7f => self.draw_right_and_lower_one_eighth_block(canvas),
        0x1fb80 => self.draw_upper_and_lower_one_eighth_block(canvas),
        0x1fb81 => self.draw_horizontal_one_eighth_1358_block(canvas),

        0x1fb87 => self.draw_right_one_quarter_block(canvas),
        0x1fb88 => self.draw_right_three_eighths_block(canvas),
        0x1fb89 => self.draw_right_five_eighths_block(canvas),
        0x1fb8a => self.draw_right_three_quarters_block(canvas),
        0x1fb8b => self.draw_right_seven_eighths_block(canvas),

        // Not official box characters but special characters we hide
        // in the high bits of a unicode codepoint.
        @intFromEnum(Sprite.cursor_rect) => self.draw_cursor_rect(canvas),
        @intFromEnum(Sprite.cursor_hollow_rect) => self.draw_cursor_hollow_rect(canvas),
        @intFromEnum(Sprite.cursor_bar) => self.draw_cursor_bar(canvas),

        else => return error.InvalidCodepoint,
    }
}

fn draw_light_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
}

fn draw_heavy_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
}

fn draw_light_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle(canvas, .light);
}

fn draw_heavy_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle(canvas, .heavy);
}

fn draw_light_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.light.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_heavy_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.heavy.height(self.thickness),
        @max(4, Thickness.light.height(self.thickness)),
    );
}

fn draw_light_down_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_light_and_right_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_right_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_heavy_down_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_light_down_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_light_and_left_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_left_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_heavy_down_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_light_up_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_light_and_right_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_heavy_and_right_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .light);
}

fn draw_heavy_up_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_light_up_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_light_and_left_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_heavy_and_left_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .light);
}

fn draw_heavy_up_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_light_vertical_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle(canvas, .light);
}

fn draw_vertical_light_and_right_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle(canvas, .light);
}

fn draw_up_heavy_and_right_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_right_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_vertical_heavy_and_right_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle(canvas, .heavy);
}

fn draw_down_light_and_right_up_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_up_light_and_right_down_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_heavy_vertical_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle(canvas, .heavy);
}

fn draw_light_vertical_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle(canvas, .light);
}

fn draw_vertical_light_and_left_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.vline_middle(canvas, .light);
}

fn draw_up_heavy_and_left_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_left_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_vertical_heavy_and_left_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.vline_middle(canvas, .heavy);
}

fn draw_down_light_and_left_up_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_up_light_and_left_down_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_heavy_vertical_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.vline_middle(canvas, .heavy);
}

fn draw_light_down_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_left_heavy_and_right_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_right_heavy_and_left_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_light_and_horizontal_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_horizontal_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_right_light_and_left_down_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_left_light_and_right_down_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_heavy_down_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_light_up_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_left_heavy_and_right_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_right_heavy_and_left_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_light_and_horizontal_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_up_heavy_and_horizontal_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_up(canvas, .heavy, .light);
}

fn draw_right_light_and_left_up_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_left_light_and_right_up_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_heavy_up_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_light_vertical_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle(canvas, .light);
}

fn draw_left_heavy_and_right_vertical_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle(canvas, .light);
}

fn draw_right_heavy_and_left_vertical_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .light, .heavy);
    self.vline_middle(canvas, .light);
}

fn draw_vertical_light_and_horizontal_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle(canvas, .light);
}

fn draw_up_heavy_and_down_horizontal_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_down_heavy_and_up_horizontal_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .light);
}

fn draw_vertical_heavy_and_horizontal_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .light);
    self.vline_middle(canvas, .heavy);
}

fn draw_left_up_heavy_and_right_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_right_up_heavy_and_left_down_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_left_down_heavy_and_right_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_right_down_heavy_and_left_up_light(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_down_light_and_up_horizontal_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_up_light_and_down_horizontal_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_right_light_and_left_vertical_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
    self.vline_middle(canvas, .heavy);
}

fn draw_left_light_and_right_vertical_heavy(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
    self.vline_middle(canvas, .heavy);
}

fn draw_heavy_vertical_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle(canvas, .heavy);
    self.vline_middle(canvas, .heavy);
}

fn draw_light_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.light.height(self.thickness),
        Thickness.light.height(self.thickness),
    );
}

fn draw_heavy_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.heavy.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_light_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.light.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_heavy_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.heavy.height(self.thickness),
        Thickness.heavy.height(self.thickness),
    );
}

fn draw_double_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const mid = (self.height - thick_px * 3) / 2;
    self.hline(canvas, 0, self.width, mid, thick_px);
    self.hline(canvas, 0, self.width, mid + 2 * thick_px, thick_px);
}

fn draw_double_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const mid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, self.height, mid, thick_px);
    self.vline(canvas, 0, self.height, mid + 2 * thick_px, thick_px);
}

fn draw_down_single_and_right_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px) / 2;
    self.vline_middle_down(canvas, .light, .light);
    self.hline(canvas, vmid, self.width, hmid, thick_px);
    self.hline(canvas, vmid, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_down_double_and_right_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle_right(canvas, .light, .light);
    self.vline(canvas, hmid, self.height, vmid, thick_px);
    self.vline(canvas, hmid, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_down_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, hmid, self.height, vmid, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, vmid, self.width, hmid, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_down_single_and_left_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width + thick_px) / 2;
    self.vline_middle_down(canvas, .light, .light);
    self.hline(canvas, 0, vmid, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_down_double_and_left_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle_left(canvas, .light, .light);
    self.vline(canvas, hmid, self.height, vmid, thick_px);
    self.vline(canvas, hmid, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_down_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid, thick_px);
    self.vline(canvas, hmid, self.height, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, 0, vmid + 2 * thick_px, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_up_single_and_right_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px) / 2;
    self.vline_middle_up(canvas, .light, .light);
    self.hline(canvas, vmid, self.width, hmid, thick_px);
    self.hline(canvas, vmid, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_up_double_and_right_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height + thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle_right(canvas, .light, .light);
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
}

fn draw_double_up_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, hmid + 2 * thick_px, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid, thick_px);
    self.hline(canvas, vmid, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_up_single_and_left_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width + thick_px) / 2;
    self.vline_middle_up(canvas, .light, .light);
    self.hline(canvas, 0, vmid, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_up_double_and_left_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height + thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle_left(canvas, .light, .light);
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
}

fn draw_double_up_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, hmid + 0 * thick_px + thick_px, vmid, thick_px);
    self.vline(canvas, 0, hmid + 2 * thick_px + thick_px, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, 0, vmid, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_single_and_right_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px) / 2;
    self.vline_middle(canvas, .light);
    self.hline(canvas, vmid, self.width, hmid, thick_px);
    self.hline(canvas, vmid, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_double_and_right_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline(canvas, vmid + 2 * thick_px, self.width, (self.height - thick_px) / 2, thick_px);
    self.vline(canvas, 0, self.height, vmid, thick_px);
    self.vline(canvas, 0, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_vertical_and_right(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, self.height, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_single_and_left_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width + thick_px) / 2;
    self.vline_middle(canvas, .light);
    self.hline(canvas, 0, vmid, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_double_and_left_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline(canvas, 0, vmid, (self.height - thick_px) / 2, thick_px);
    self.vline(canvas, 0, self.height, vmid, thick_px);
    self.vline(canvas, 0, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_vertical_and_left(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, self.height, vmid + 2 * thick_px, thick_px);
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid, thick_px);
    self.hline(canvas, 0, vmid + thick_px, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
}

fn draw_down_single_and_horizontal_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    self.vline(canvas, hmid + 2 * thick_px, self.height, (self.width - thick_px) / 2, thick_px);
    self.hline(canvas, 0, self.width, hmid, thick_px);
    self.hline(canvas, 0, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_down_double_and_horizontal_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle(canvas, .light);
    self.vline(canvas, hmid, self.height, vmid, thick_px);
    self.vline(canvas, hmid, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_down_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline(canvas, 0, self.width, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid + 2 * thick_px, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_up_single_and_horizontal_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px) / 2;
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.hline(canvas, 0, self.width, hmid, thick_px);
    self.hline(canvas, 0, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_up_double_and_horizontal_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle(canvas, .light);
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
}

fn draw_double_up_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.vline(canvas, 0, hmid, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
    self.hline(canvas, 0, vmid + thick_px, hmid, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid, thick_px);
    self.hline(canvas, 0, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_single_and_horizontal_double(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    self.vline_middle(canvas, .light);
    self.hline(canvas, 0, self.width, hmid, thick_px);
    self.hline(canvas, 0, self.width, hmid + 2 * thick_px, thick_px);
}

fn draw_vertical_double_and_horizontal_single(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline_middle(canvas, .light);
    self.vline(canvas, 0, self.height, vmid, thick_px);
    self.vline(canvas, 0, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_double_vertical_and_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    const hmid = (self.height - thick_px * 3) / 2;
    const vmid = (self.width - thick_px * 3) / 2;
    self.hline(canvas, 0, vmid, hmid, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid, thick_px);
    self.hline(canvas, 0, vmid, hmid + 2 * thick_px, thick_px);
    self.hline(canvas, vmid + 2 * thick_px, self.width, hmid + 2 * thick_px, thick_px);
    self.vline(canvas, 0, hmid + thick_px, vmid, thick_px);
    self.vline(canvas, 0, hmid, vmid + 2 * thick_px, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid, thick_px);
    self.vline(canvas, hmid + 2 * thick_px, self.height, vmid + 2 * thick_px, thick_px);
}

fn draw_light_diagonal_upper_right_to_lower_left(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    canvas.trapezoid(.{
        .top = 0,
        .bottom = @as(i32, @intCast(self.height)),
        .left = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(0 - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
        .right = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(0 + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
    });
}

fn draw_light_diagonal_upper_left_to_lower_right(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);
    canvas.trapezoid(.{
        .top = 0,
        .bottom = @as(i32, @intCast(self.height)),
        .left = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(0 - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) - @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
        .right = .{
            .p1 = .{
                .x = @as(i32, @intFromFloat(0 + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = 0,
            },

            .p2 = .{
                .x = @as(i32, @intFromFloat(@as(f64, @floatFromInt(self.width)) + @as(f64, @floatFromInt(thick_px)) / 2)),
                .y = @as(i32, @intCast(self.height)),
            },
        },
    });
}

fn draw_light_diagonal_cross(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_light_diagonal_upper_right_to_lower_left(canvas);
    self.draw_light_diagonal_upper_left_to_lower_right(canvas);
}

fn draw_light_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
}

fn draw_light_up(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_up(canvas, .light, .light);
}

fn draw_light_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .light, .light);
}

fn draw_light_down(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_heavy_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
}

fn draw_heavy_up(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_up(canvas, .heavy, .heavy);
}

fn draw_heavy_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_right(canvas, .heavy, .heavy);
}

fn draw_heavy_down(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_light_left_and_heavy_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .light, .light);
    self.hline_middle_right(canvas, .heavy, .heavy);
}

fn draw_light_up_and_heavy_down(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_up(canvas, .light, .light);
    self.vline_middle_down(canvas, .heavy, .heavy);
}

fn draw_heavy_left_and_light_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.hline_middle_left(canvas, .heavy, .heavy);
    self.hline_middle_right(canvas, .light, .light);
}

fn draw_heavy_up_and_light_down(self: Box, canvas: *font.sprite.Canvas) void {
    self.vline_middle_up(canvas, .heavy, .heavy);
    self.vline_middle_down(canvas, .light, .light);
}

fn draw_upper_half_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, 0, self.width, self.height / 2);
}

fn draw_lower_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, self.height - (self.height / 8), self.width, self.height);
}

fn draw_lower_one_quarter_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, self.height - (self.height / 4), self.width, self.height);
}

fn draw_lower_three_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        self.height - @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.height)) / 8))),
        self.width,
        self.height,
    );
}

fn draw_lower_half_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        self.height - @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.height)) / 2))),
        self.width,
        self.height,
    );
}

fn draw_lower_five_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        self.height - @as(u32, @intFromFloat(@round(5 * @as(f64, @floatFromInt(self.height)) / 8))),
        self.width,
        self.height,
    );
}

fn draw_lower_three_quarters_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        self.height - @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.height)) / 4))),
        self.width,
        self.height,
    );
}

fn draw_lower_seven_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        self.height - @as(u32, @intFromFloat(@round(7 * @as(f64, @floatFromInt(self.height)) / 8))),
        self.width,
        self.height,
    );
}

fn draw_upper_one_quarter_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        self.width,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.height)) / 4))),
    );
}

fn draw_upper_three_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        self.width,
        @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.height)) / 8))),
    );
}

fn draw_upper_five_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        self.width,
        @as(u32, @intFromFloat(@round(5 * @as(f64, @floatFromInt(self.height)) / 8))),
    );
}

fn draw_upper_three_quarters_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        self.width,
        @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.height)) / 4))),
    );
}

fn draw_upper_seven_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        self.width,
        @as(u32, @intFromFloat(@round(7 * @as(f64, @floatFromInt(self.height)) / 8))),
    );
}

fn draw_full_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, 0, self.width, self.height);
}

fn draw_left_seven_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(7 * @as(f64, @floatFromInt(self.width)) / 8))),
        self.height,
    );
}

fn draw_left_three_quarters_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.width)) / 4))),
        self.height,
    );
}

fn draw_left_five_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(5 * @as(f64, @floatFromInt(self.width)) / 8))),
        self.height,
    );
}

fn draw_left_half_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 2))),
        self.height,
    );
}

fn draw_left_three_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.width)) / 8))),
        self.height,
    );
}

fn draw_left_one_quarter_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 4))),
        self.height,
    );
}

fn draw_vertical_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const x = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.width)) / 8)));
    const w = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 8)));
    self.rect(canvas, x, 0, x + w, self.height);
}

fn draw_left_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_vertical_one_eighth_block_n(canvas, 0);
}

fn draw_right_half_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 2))),
        0,
        self.width,
        self.height,
    );
}

fn draw_pixman_shade(self: Box, canvas: *font.sprite.Canvas, v: u16) void {
    canvas.rect((font.sprite.Box{
        .x1 = 0,
        .y1 = 0,
        .x2 = @as(i32, @intCast(self.width)),
        .y2 = @as(i32, @intCast(self.height)),
    }).rect(), @as(font.sprite.Color, @enumFromInt(v)));
}

fn draw_light_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0x40);
}

fn draw_medium_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0x80);
}

fn draw_dark_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_pixman_shade(canvas, 0xc0);
}

fn draw_horizontal_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const y = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.height)) / 8)));
    const h = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.height)) / 8)));
    self.rect(canvas, 0, y, self.width, y + h);
}

fn draw_upper_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_horizontal_one_eighth_block_n(canvas, 0);
}

fn draw_right_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 8))),
        0,
        self.width,
        self.height,
    );
}

fn draw_left_and_lower_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_left_one_eighth_block(canvas);
    self.draw_lower_one_eighth_block(canvas);
}

fn draw_left_and_upper_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_left_one_eighth_block(canvas);
    self.draw_upper_one_eighth_block(canvas);
}

fn draw_right_and_upper_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_right_one_eighth_block(canvas);
    self.draw_upper_one_eighth_block(canvas);
}

fn draw_right_and_lower_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_right_one_eighth_block(canvas);
    self.draw_lower_one_eighth_block(canvas);
}

fn draw_upper_and_lower_one_eighth_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_upper_one_eighth_block(canvas);
    self.draw_lower_one_eighth_block(canvas);
}

fn draw_horizontal_one_eighth_1358_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_upper_one_eighth_block(canvas);
    self.draw_horizontal_one_eighth_block_n(canvas, 2);
    self.draw_horizontal_one_eighth_block_n(canvas, 4);
    self.draw_lower_one_eighth_block(canvas);
}

fn draw_right_one_quarter_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 4))),
        0,
        self.width,
        self.height,
    );
}

fn draw_right_three_quarters_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.width)) / 4))),
        0,
        self.width,
        self.height,
    );
}

fn draw_right_three_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(3 * @as(f64, @floatFromInt(self.width)) / 8))),
        0,
        self.width,
        self.height,
    );
}

fn draw_right_five_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(5 * @as(f64, @floatFromInt(self.width)) / 8))),
        0,
        self.width,
        self.height,
    );
}

fn draw_right_seven_eighths_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        self.width - @as(u32, @intFromFloat(@round(7 * @as(f64, @floatFromInt(self.width)) / 8))),
        0,
        self.width,
        self.height,
    );
}

fn quad_upper_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        0,
        @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(self.width)) / 2))),
        @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(self.height)) / 2))),
    );
}

fn quad_upper_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(self.width)) / 2))),
        0,
        self.width,
        @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(self.height)) / 2))),
    );
}

fn quad_lower_left(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        0,
        @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(self.height)) / 2))),
        @as(u32, @intFromFloat(@ceil(@as(f64, @floatFromInt(self.width)) / 2))),
        self.height,
    );
}

fn quad_lower_right(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(
        canvas,
        @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(self.width)) / 2))),
        @as(u32, @intFromFloat(@floor(@as(f64, @floatFromInt(self.height)) / 2))),
        self.width,
        self.height,
    );
}

fn draw_quadrant(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    const UPPER_LEFT: u8 = 1 << 0;
    const UPPER_RIGHT: u8 = 1 << 1;
    const LOWER_LEFT: u8 = 1 << 2;
    const LOWER_RIGHT: u8 = 1 << 3;
    const matrix: [10]u8 = .{
        LOWER_LEFT,
        LOWER_RIGHT,
        UPPER_LEFT,
        UPPER_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT,
        UPPER_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
    };

    assert(cp >= 0x2596 and cp <= 0x259f);
    const idx = cp - 0x2596;
    const encoded = matrix[idx];

    if (encoded & UPPER_LEFT == UPPER_LEFT) self.quad_upper_left(canvas);
    if (encoded & UPPER_RIGHT == UPPER_RIGHT) self.quad_upper_right(canvas);
    if (encoded & LOWER_LEFT == LOWER_LEFT) self.quad_lower_left(canvas);
    if (encoded & LOWER_RIGHT == LOWER_RIGHT) self.quad_lower_right(canvas);
}

fn draw_braille(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    var w: u32 = @min(self.width / 4, self.height / 8);
    var x_spacing: u32 = self.width / 4;
    var y_spacing: u32 = self.height / 8;
    var x_margin: u32 = x_spacing / 2;
    var y_margin: u32 = y_spacing / 2;

    var x_px_left: u32 = self.width - 2 * x_margin - x_spacing - 2 * w;
    var y_px_left: u32 = self.height - 2 * y_margin - 3 * y_spacing - 4 * w;

    // First, try hard to ensure the DOT width is non-zero
    if (x_px_left >= 2 and y_px_left >= 4 and w == 0) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    // Second, prefer a non-zero margin
    if (x_px_left >= 2 and x_margin == 0) {
        x_margin = 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2 and y_margin == 0) {
        y_margin = 1;
        y_px_left -= 2;
    }

    // Third, increase spacing
    if (x_px_left >= 1) {
        x_spacing += 1;
        x_px_left -= 1;
    }
    if (y_px_left >= 3) {
        y_spacing += 1;
        y_px_left -= 3;
    }

    // Fourth, margins (“spacing”, but on the sides)
    if (x_px_left >= 2) {
        x_margin += 1;
        x_px_left -= 2;
    }
    if (y_px_left >= 2) {
        y_margin += 1;
        y_px_left -= 2;
    }

    // Last - increase dot width
    if (x_px_left >= 2 and y_px_left >= 4) {
        w += 1;
        x_px_left -= 2;
        y_px_left -= 4;
    }

    assert(x_px_left <= 1 or y_px_left <= 1);
    assert(2 * x_margin + 2 * w + x_spacing <= self.width);
    assert(2 * y_margin + 4 * w + 3 * y_spacing <= self.height);

    const x = [2]u32{ x_margin, x_margin + w + x_spacing };
    const y = y: {
        var y: [4]u32 = undefined;
        y[0] = y_margin;
        y[1] = y[0] + w + y_spacing;
        y[2] = y[1] + w + y_spacing;
        y[3] = y[2] + w + y_spacing;
        break :y y;
    };

    assert(cp >= 0x2800);
    assert(cp <= 0x28ff);
    const sym = cp - 0x2800;

    // Left side
    if (sym & 1 > 0)
        self.rect(canvas, x[0], y[0], x[0] + w, y[0] + w);
    if (sym & 2 > 0)
        self.rect(canvas, x[0], y[1], x[0] + w, y[1] + w);
    if (sym & 4 > 0)
        self.rect(canvas, x[0], y[2], x[0] + w, y[2] + w);

    // Right side
    if (sym & 8 > 0)
        self.rect(canvas, x[1], y[0], x[1] + w, y[0] + w);
    if (sym & 16 > 0)
        self.rect(canvas, x[1], y[1], x[1] + w, y[1] + w);
    if (sym & 32 > 0)
        self.rect(canvas, x[1], y[2], x[1] + w, y[2] + w);

    // 8-dot patterns
    if (sym & 64 > 0)
        self.rect(canvas, x[0], y[3], x[0] + w, y[3] + w);
    if (sym & 128 > 0)
        self.rect(canvas, x[1], y[3], x[1] + w, y[3] + w);
}

fn draw_sextant(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    const UPPER_LEFT: u8 = 1 << 0;
    const MIDDLE_LEFT: u8 = 1 << 1;
    const LOWER_LEFT: u8 = 1 << 2;
    const UPPER_RIGHT: u8 = 1 << 3;
    const MIDDLE_RIGHT: u8 = 1 << 4;
    const LOWER_RIGHT: u8 = 1 << 5;

    const matrix: [60]u8 = .{
        // U+1fb00 - U+1fb0f
        UPPER_LEFT,
        UPPER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT,
        MIDDLE_LEFT,
        UPPER_LEFT | MIDDLE_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT,
        MIDDLE_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT,
        UPPER_RIGHT | MIDDLE_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT,
        LOWER_LEFT,

        // U+1fb10 - U+1fb1f
        UPPER_LEFT | LOWER_LEFT,
        UPPER_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT,
        MIDDLE_LEFT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT,
        MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT,
        LOWER_RIGHT,
        UPPER_LEFT | LOWER_RIGHT,

        // U+1fb20 - U+1fb2f
        UPPER_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | LOWER_RIGHT,
        MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_RIGHT,
        MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_RIGHT,
        LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,

        // U+1fb30 - U+1fb3b
        UPPER_LEFT | UPPER_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_LEFT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | UPPER_RIGHT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_LEFT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
        UPPER_RIGHT | MIDDLE_LEFT | MIDDLE_RIGHT | LOWER_LEFT | LOWER_RIGHT,
    };

    assert(cp >= 0x1fb00 and cp <= 0x1fb3b);
    const idx = cp - 0x1fb00;
    const encoded = matrix[idx];

    const x_halfs = self.xHalfs();
    const y_thirds = self.yThirds();

    if (encoded & UPPER_LEFT > 0) self.rect(canvas, 0, 0, x_halfs[0], y_thirds[0]);
    if (encoded & MIDDLE_LEFT > 0) self.rect(canvas, 0, y_thirds[0], x_halfs[0], y_thirds[1]);
    if (encoded & LOWER_LEFT > 0) self.rect(canvas, 0, y_thirds[1], x_halfs[0], self.height);
    if (encoded & UPPER_RIGHT > 0) self.rect(canvas, x_halfs[1], 0, self.width, y_thirds[0]);
    if (encoded & MIDDLE_RIGHT > 0) self.rect(canvas, x_halfs[1], y_thirds[0], self.width, y_thirds[1]);
    if (encoded & LOWER_RIGHT > 0) self.rect(canvas, x_halfs[1], y_thirds[1], self.width, self.height);
}

fn xHalfs(self: Box) [2]u32 {
    return .{
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.width)) / 2))),
        @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.width)) / 2)),
    };
}

fn yThirds(self: Box) [2]u32 {
    return switch (@mod(self.height, 3)) {
        0 => .{ self.height / 3, 2 * self.height / 3 },
        1 => .{ self.height / 3, 2 * self.height / 3 + 1 },
        2 => .{ self.height / 3 + 1, 2 * self.height / 3 },
        else => unreachable,
    };
}

fn draw_wedge_triangle(self: Box, canvas: *font.sprite.Canvas, cp: u32) !void {
    const width = self.width;
    const height = self.height;

    const x_halfs = self.xHalfs();
    const y_thirds = self.yThirds();
    const halfs0 = x_halfs[0];
    const halfs1 = x_halfs[1];
    const thirds0 = y_thirds[0];
    const thirds1 = y_thirds[1];

    var p1_x: u32 = 0;
    var p2_x: u32 = 0;
    var p3_x: u32 = 0;
    var p1_y: u32 = 0;
    var p2_y: u32 = 0;
    var p3_y: u32 = 0;

    switch (cp) {
        0x1fb3c => {
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb52 => {
            p3_x = halfs0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3d => {
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb53 => {
            p3_x = width;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3e => {
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb54 => {
            p3_x = halfs0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb3f => {
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb55 => {
            p3_x = width;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb40, 0x1fb56 => {
            p3_x = halfs0;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb47 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5d => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb48 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5e => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds1;
            p2_y = height;
            p3_y = height;
        },

        0x1fb49 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb5f => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4a => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb60 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p1_y = thirds0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb4b, 0x1fb61 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p1_y = 0;
            p2_y = height;
            p3_y = height;
        },

        0x1fb57 => {
            p3_x = halfs0;
            p2_y = thirds0;
        },

        0x1fb41 => {
            p3_x = halfs0;
            p2_y = thirds0;
        },

        0x1fb58 => {
            p3_x = width;
            p2_y = thirds0;
        },

        0x1fb42 => {
            p3_x = width;
            p2_y = thirds0;
        },

        0x1fb59 => {
            p3_x = halfs0;
            p2_y = thirds1;
        },

        0x1fb43 => {
            p3_x = halfs0;
            p2_y = thirds1;
        },

        0x1fb5a => {
            p3_x = width;
            p2_y = thirds1;
        },

        0x1fb44 => {
            p3_x = width;
            p2_y = thirds1;
        },

        0x1fb5b, 0x1fb45 => {
            p3_x = halfs0;
            p2_y = height;
        },

        0x1fb62 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds0;
        },

        0x1fb4c => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds0;
        },

        0x1fb63 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds0;
        },

        0x1fb4d => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds0;
        },

        0x1fb64 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds1;
        },

        0x1fb4e => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = thirds1;
        },

        0x1fb65 => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds1;
        },

        0x1fb4f => {
            p1_x = width;
            p2_x = width;
            p3_x = 0;
            p2_y = thirds1;
        },

        0x1fb66, 0x1fb50 => {
            p1_x = width;
            p2_x = width;
            p3_x = halfs1;
            p2_y = height;
        },

        0x1fb46 => {
            p1_x = 0;
            p1_y = thirds1;
            p2_x = width;
            p2_y = thirds0;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb51 => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p2_y;
        },

        0x1fb5c => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = 0;
            p2_y = thirds1;
            p3_x = width;
            p3_y = p1_y;
        },

        0x1fb67 => {
            p1_x = 0;
            p1_y = thirds0;
            p2_x = width;
            p2_y = p1_y;
            p3_x = width;
            p3_y = thirds1;
        },

        0x1fb6c, 0x1fb68 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs0;
            p2_y = height / 2;
            p3_x = 0;
            p3_y = height;
        },

        0x1fb6d, 0x1fb69 => {
            p1_x = 0;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = height / 2;
            p3_x = width;
            p3_y = 0;
        },

        0x1fb6e, 0x1fb6a => {
            p1_x = width;
            p1_y = 0;
            p2_x = halfs1;
            p2_y = height / 2;
            p3_x = width;
            p3_y = height;
        },

        0x1fb6f, 0x1fb6b => {
            p1_x = 0;
            p1_y = height;
            p2_x = halfs1;
            p2_y = height / 2;
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

fn draw_wedge_triangle_inverted(
    self: Box,
    alloc: Allocator,
    canvas: *font.sprite.Canvas,
    cp: u32,
) !void {
    try self.draw_wedge_triangle(canvas, cp);

    var src = try font.sprite.Canvas.init(alloc, self.width, self.height);
    src.rect(.{ .x = 0, .y = 0, .width = self.width, .height = self.height }, .on);
    defer src.deinit(alloc);
    canvas.composite(
        .source_out,
        &src,
        .{ .x = 0, .y = 0, .width = self.width, .height = self.height },
    );
}

fn draw_wedge_triangle_and_box(self: Box, canvas: *font.sprite.Canvas, cp: u32) !void {
    try self.draw_wedge_triangle(canvas, cp);

    const y_thirds = self.yThirds();
    const box: font.sprite.Box = switch (cp) {
        0x1fb46, 0x1fb51 => .{
            .x1 = 0,
            .y1 = @as(i32, @intCast(y_thirds[1])),
            .x2 = @as(i32, @intCast(self.width)),
            .y2 = @as(i32, @intCast(self.height)),
        },

        0x1fb5c, 0x1fb67 => .{
            .x1 = 0,
            .y1 = 0,
            .x2 = @as(i32, @intCast(self.width)),
            .y2 = @as(i32, @intCast(y_thirds[0])),
        },

        else => unreachable,
    };

    canvas.rect(box.rect(), .on);
}

fn draw_light_arc(
    self: Box,
    alloc: Allocator,
    canvas: *font.sprite.Canvas,
    cp: u32,
) !void {
    const supersample = 4;
    const height = self.height * supersample;
    const width = self.width * supersample;

    // Allocate our supersample sized canvas
    var ss_data = try alloc.alloc(u8, height * width);
    defer alloc.free(ss_data);
    @memset(ss_data, 0);

    const height_pixels = self.height;
    const width_pixels = self.width;
    const thick_pixels = Thickness.light.height(self.thickness);
    const thick = thick_pixels * supersample;

    const circle_inner_edge = (@min(width_pixels, height_pixels) - thick_pixels) / 2;

    // We want to draw the quartercircle by filling small circles (with r =
    // thickness/2.) whose centers are on its edge. This means to get the
    // radius of the quartercircle, we add the exact half thickness to the
    // radius of the inner circle.
    var c_r: f64 = @as(f64, @floatFromInt(circle_inner_edge)) + @as(f64, @floatFromInt(thick_pixels)) / 2;

    // We need to draw short lines from the end of the quartercircle to the
    // box-edges, store one endpoint (the other is the edge of the
    // quartercircle) in these vars.
    var vert_to: u32 = 0;
    var hor_to: u32 = 0;

    // Coordinates of the circle-center.
    var c_x: u32 = 0;
    var c_y: u32 = 0;

    // For a given y there are up to two solutions for the circle-equation.
    // Set to -1 for the left, and 1 for the right hemisphere.
    var circle_hemisphere: i32 = 0;

    // The quarter circle only has to be evaluated for a small range of
    // y-values.
    var y_min: u32 = 0;
    var y_max: u32 = 0;

    switch (cp) {
        '╭' => {
            // Don't use supersampled coordinates yet, we want to align actual
            // pixels.
            //
            // pixel-coordinates of the lower edge of the right line and the
            // right edge of the bottom line.
            const right_bottom_edge = (height_pixels + thick_pixels) / 2;
            const bottom_right_edge = (width_pixels + thick_pixels) / 2;

            // find coordinates of circle-center.
            c_y = right_bottom_edge + circle_inner_edge;
            c_x = bottom_right_edge + circle_inner_edge;

            // we want to render the left, not the right hemisphere of the circle.
            circle_hemisphere = -1;

            // don't evaluate beyond c_y, the vertical line is drawn there.
            y_min = 0;
            y_max = c_y;

            // the vertical line should extend to the bottom of the box, the
            // horizontal to the right.
            vert_to = height_pixels;
            hor_to = width_pixels;
        },
        '╮' => {
            const left_bottom_edge = (height_pixels + thick_pixels) / 2;
            const bottom_left_edge = (width_pixels - thick_pixels) / 2;

            c_y = left_bottom_edge + circle_inner_edge;
            c_x = bottom_left_edge - circle_inner_edge;

            circle_hemisphere = 1;

            y_min = 0;
            y_max = c_y;

            vert_to = height_pixels;
            hor_to = 0;
        },
        '╰' => {
            const right_top_edge = (height_pixels - thick_pixels) / 2;
            const top_right_edge = (width_pixels + thick_pixels) / 2;

            c_y = right_top_edge - circle_inner_edge;
            c_x = top_right_edge + circle_inner_edge;

            circle_hemisphere = -1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = width_pixels;
        },
        '╯' => {
            const left_top_edge = (height_pixels - thick_pixels) / 2;
            const top_left_edge = (width_pixels - thick_pixels) / 2;

            c_y = left_top_edge - circle_inner_edge;
            c_x = top_left_edge - circle_inner_edge;

            circle_hemisphere = 1;

            y_min = c_y;
            y_max = height_pixels;

            vert_to = 0;
            hor_to = 0;
        },

        else => {},
    }

    // store for horizontal+vertical line.
    const c_x_pixels = c_x;
    const c_y_pixels = c_y;

    // Bring coordinates from pixel-grid to supersampled grid.
    c_r *= supersample;
    c_x *= supersample;
    c_y *= supersample;

    y_min *= supersample;
    y_max *= supersample;

    const c_r2 = c_r * c_r;

    // To prevent gaps in the circle, each pixel is sampled multiple times.
    // As the quartercircle ends (vertically) in the middle of a pixel, an
    // uneven number helps hit that exactly.
    {
        var i: f64 = @as(f64, @floatFromInt(y_min)) * 16;
        while (i <= @as(f64, @floatFromInt(y_max)) * 16) : (i += 1) {
            const y = i / 16;
            const x = x: {
                // circle_hemisphere * sqrt(c_r2 - (y - c_y) * (y - c_y)) + c_x;
                const hemi = @as(f64, @floatFromInt(circle_hemisphere));
                const y_part = y - @as(f64, @floatFromInt(c_y));
                const y_squared = y_part * y_part;
                const sqrt = @sqrt(c_r2 - y_squared);
                const f_c_x = @as(f64, @floatFromInt(c_x));

                // We need to detect overflows and just skip this i
                const a = hemi * sqrt;
                const b = a + f_c_x;

                // If the float math didn't work, ignore.
                if (std.math.isNan(b)) continue;

                break :x b;
            };

            const row = @as(i32, @intFromFloat(@round(y)));
            const col = @as(i32, @intFromFloat(@round(x)));
            if (col < 0) continue;

            // rectangle big enough to fit entire circle with radius thick/2.
            const row1 = row - @as(i32, @intCast(thick / 2 + 1));
            const row2 = row + @as(i32, @intCast(thick / 2 + 1));
            const col1 = col - @as(i32, @intCast(thick / 2 + 1));
            const col2 = col + @as(i32, @intCast(thick / 2 + 1));

            const row_start = @min(row1, row2);
            const row_end = @max(row1, row2);
            const col_start = @min(col1, col2);
            const col_end = @max(col1, col2);

            assert(row_end > row_start);
            assert(col_end > col_start);

            // draw circle with radius thick/2 around x,y.
            // this is accomplished by rejecting pixels where the distance from
            // their center to x,y is greater than thick/2.
            var r: i32 = @max(row_start, 0);
            const r_end = @max(@min(row_end, @as(i32, @intCast(height))), 0);
            while (r < r_end) : (r += 1) {
                const r_midpoint = @as(f64, @floatFromInt(r)) + 0.5;

                var c: i32 = @max(col_start, 0);
                const c_end = @max(@min(col_end, @as(i32, @intCast(width))), 0);
                while (c < c_end) : (c += 1) {
                    const c_midpoint = @as(f64, @floatFromInt(c)) + 0.5;

                    // vector from point on quartercircle to midpoint of the current pixel.
                    const center_midpoint_x = c_midpoint - x;
                    const center_midpoint_y = r_midpoint - y;

                    // distance from current point to circle-center.
                    const dist = @sqrt(center_midpoint_x * center_midpoint_x + center_midpoint_y * center_midpoint_y);
                    // skip if midpoint of pixel is outside the circle.
                    if (dist > @as(f64, @floatFromInt(thick)) / 2) continue;

                    // Set our pixel
                    const idx = @as(usize, @intCast(r * @as(i32, @intCast(width)) + c));
                    ss_data[idx] = 0xFF;
                }
            }
        }
    }

    // Downsample
    {
        var r: u32 = 0;
        while (r < self.height) : (r += 1) {
            var c: u32 = 0;
            while (c < self.width) : (c += 1) {
                var total: u32 = 0;
                var i: usize = 0;
                while (i < supersample) : (i += 1) {
                    var j: usize = 0;
                    while (j < supersample) : (j += 1) {
                        const idx = (r * supersample + i) * width + (c * supersample + j);
                        total += ss_data[idx];
                    }
                }

                const average = @as(u8, @intCast(@min(total / (supersample * supersample), 0xff)));
                canvas.rect(
                    .{
                        .x = @as(i32, @intCast(c)),
                        .y = @as(i32, @intCast(r)),
                        .width = 1,
                        .height = 1,
                    },
                    @as(font.sprite.Color, @enumFromInt(average)),
                );
            }
        }
    }

    // draw vertical/horizontal lines from quartercircle-edge to box-edge.
    self.vline(canvas, @min(c_y_pixels, vert_to), @max(c_y_pixels, vert_to), (width_pixels - thick_pixels) / 2, thick_pixels);
    self.hline(canvas, @min(c_x_pixels, hor_to), @max(c_x_pixels, hor_to), (height_pixels - thick_pixels) / 2, thick_pixels);
}

fn draw_dash_horizontal(
    self: Box,
    canvas: *font.sprite.Canvas,
    count: u8,
    thick_px: u32,
    gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // The number of gaps we have is one less than the number of dashes.
    // "- - -" => 2 gaps
    const gap_count = count - 1;

    // Determine the width of our dashes
    const dash_width = dash_width: {
        var gap_i = gap;
        var dash_width = (self.width - (gap_count * gap_i)) / count;
        while (dash_width <= 0 and gap_i > 1) {
            gap_i -= 1;
            dash_width = (self.width - (gap_count * gap_i)) / count;
        }

        // If we can't fit any dashes then we just render a horizontal line.
        if (dash_width <= 0) {
            self.hline_middle(canvas, .light);
            return;
        }

        break :dash_width dash_width;
    };

    // Our total width should be less than our real width
    assert(count * dash_width + gap_count * gap <= self.width);
    const remaining = self.width - count * dash_width - gap_count * gap;

    var x: [4]u32 = .{0} ** 4;
    var w: [4]u32 = .{dash_width} ** 4;
    x[1] = x[0] + w[0] + gap;
    if (count == 2)
        w[1] = self.width - x[1]
    else if (count == 3)
        w[1] += remaining
    else
        w[1] += remaining / 2;

    if (count >= 3) {
        x[2] = x[1] + w[1] + gap;
        if (count == 3)
            w[2] = self.width - x[2]
        else
            w[2] += remaining - remaining / 2;
    }

    if (count >= 4) {
        x[3] = x[2] + w[2] + gap;
        w[3] = self.width - x[3];
    }

    self.hline(canvas, x[0], x[0] + w[0], (self.height - thick_px) / 2, thick_px);
    self.hline(canvas, x[1], x[1] + w[1], (self.height - thick_px) / 2, thick_px);
    if (count >= 3)
        self.hline(canvas, x[2], x[2] + w[2], (self.height - thick_px) / 2, thick_px);
    if (count >= 4)
        self.hline(canvas, x[3], x[3] + w[3], (self.height - thick_px) / 2, thick_px);
}

fn draw_dash_vertical(
    self: Box,
    canvas: *font.sprite.Canvas,
    count: u8,
    thick_px: u32,
    gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // The number of gaps we have is one less than the number of dashes.
    // "- - -" => 2 gaps
    const gap_count = count - 1;

    // Determine the height of our dashes
    const dash_height = dash_height: {
        var gap_i = gap;
        var dash_height = (self.height - (gap_count * gap_i)) / count;
        while (dash_height <= 0 and gap_i > 1) {
            gap_i -= 1;
            dash_height = (self.height - (gap_count * gap_i)) / count;
        }

        // If we can't fit any dashes then we just render a horizontal line.
        if (dash_height <= 0) {
            self.vline_middle(canvas, .light);
            return;
        }

        break :dash_height dash_height;
    };

    // Our total height should be less than our real height
    assert(count * dash_height + gap_count * gap <= self.height);
    const remaining = self.height - count * dash_height - gap_count * gap;

    var y: [4]u32 = .{0} ** 4;
    var h: [4]u32 = .{dash_height} ** 4;
    y[1] = y[0] + h[0] + gap;
    if (count == 2)
        h[1] = self.height - y[1]
    else if (count == 3)
        h[1] += remaining
    else
        h[1] += remaining / 2;

    if (count >= 3) {
        y[2] = y[1] + h[1] + gap;
        if (count == 3)
            h[2] = self.height - y[2]
        else
            h[2] += remaining - remaining / 2;
    }

    if (count >= 4) {
        y[3] = y[2] + h[2] + gap;
        h[3] = self.height - y[3];
    }

    self.vline(canvas, y[0], y[0] + h[0], (self.width - thick_px) / 2, thick_px);
    self.vline(canvas, y[1], y[1] + h[1], (self.width - thick_px) / 2, thick_px);
    if (count >= 3)
        self.vline(canvas, y[2], y[2] + h[2], (self.width - thick_px) / 2, thick_px);
    if (count >= 4)
        self.vline(canvas, y[3], y[3] + h[3], (self.width - thick_px) / 2, thick_px);
}

fn draw_cursor_rect(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.super_light.height(self.thickness);

    self.rect(canvas, 0, 0, self.width - thick_px, self.height - thick_px);
}

fn draw_cursor_hollow_rect(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.super_light.height(self.thickness);

    self.vline(canvas, 0, self.height, 0, thick_px);
    self.vline(canvas, 0, self.height, self.width - thick_px, thick_px);
    self.hline(canvas, 0, self.width, 0, thick_px);
    self.hline(canvas, 0, self.width, self.height - thick_px, thick_px);
}

fn draw_cursor_bar(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.thickness);

    self.vline(canvas, 0, self.height - thick_px, 0, thick_px);
}

fn vline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.thickness);
    self.vline(canvas, 0, self.height, (self.width - thick_px) / 2, thick_px);
}

fn vline_middle_up(
    self: Box,
    canvas: *font.sprite.Canvas,
    vthickness: Thickness,
    hthickness: Thickness,
) void {
    const hthick_px = hthickness.height(self.thickness);
    const vthick_px = vthickness.height(self.thickness);
    self.vline(
        canvas,
        0,
        (self.height + hthick_px) / 2,
        (self.width - vthick_px) / 2,
        vthick_px,
    );
}

fn vline_middle_down(
    self: Box,
    canvas: *font.sprite.Canvas,
    vthickness: Thickness,
    hthickness: Thickness,
) void {
    const hthick_px = hthickness.height(self.thickness);
    const vthick_px = vthickness.height(self.thickness);
    self.vline(
        canvas,
        (self.height - hthick_px) / 2,
        self.height,
        (self.width - vthick_px) / 2,
        vthick_px,
    );
}

fn hline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.thickness);
    self.hline(canvas, 0, self.width, (self.height - thick_px) / 2, thick_px);
}

fn hline_middle_left(
    self: Box,
    canvas: *font.sprite.Canvas,
    vthickness: Thickness,
    hthickness: Thickness,
) void {
    const hthick_px = hthickness.height(self.thickness);
    const vthick_px = vthickness.height(self.thickness);
    self.hline(
        canvas,
        0,
        (self.width + vthick_px) / 2,
        (self.height - hthick_px) / 2,
        hthick_px,
    );
}

fn hline_middle_right(
    self: Box,
    canvas: *font.sprite.Canvas,
    vthickness: Thickness,
    hthickness: Thickness,
) void {
    const hthick_px = hthickness.height(self.thickness);
    const vthick_px = vthickness.height(self.thickness);
    self.hline(
        canvas,
        (self.width - vthick_px) / 2,
        self.width,
        (self.height - hthick_px) / 2,
        hthick_px,
    );
}

fn vline(
    self: Box,
    canvas: *font.sprite.Canvas,
    y1: u32,
    y2: u32,
    x: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x, 0), self.width))),
        .x2 = @as(i32, @intCast(@min(@max(x + thickness_px, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y1, 0), self.height))),
        .y2 = @as(i32, @intCast(@min(@max(y2, 0), self.height))),
    }).rect(), .on);
}

fn hline(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    x2: u32,
    y: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x1, 0), self.width))),
        .x2 = @as(i32, @intCast(@min(@max(x2, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y, 0), self.height))),
        .y2 = @as(i32, @intCast(@min(@max(y + thickness_px, 0), self.height))),
    }).rect(), .on);
}

fn rect(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
) void {
    canvas.rect((font.sprite.Box{
        .x1 = @as(i32, @intCast(@min(@max(x1, 0), self.width))),
        .y1 = @as(i32, @intCast(@min(@max(y1, 0), self.height))),
        .x2 = @as(i32, @intCast(@min(@max(x2, 0), self.width))),
        .y2 = @as(i32, @intCast(@min(@max(y2, 0), self.height))),
    }).rect(), .on);
}

test "all" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cp: u32 = 0x2500;
    const end = 0x2570;
    while (cp <= end) : (cp += 1) {
        var atlas_greyscale = try font.Atlas.init(alloc, 512, .greyscale);
        defer atlas_greyscale.deinit(alloc);

        const face: Box = .{ .width = 18, .height = 36, .thickness = 2 };
        const glyph = try face.renderGlyph(
            alloc,
            &atlas_greyscale,
            cp,
        );
        try testing.expectEqual(@as(u32, face.width), glyph.width);
        try testing.expectEqual(@as(u32, face.height), glyph.height);
    }
}
