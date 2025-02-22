//! This file contains functions for drawing the box drawing characters
//! (https://en.wikipedia.org/wiki/Box-drawing_character) and related
//! characters that are provided by the terminal.
//!
//! The box drawing logic is based off similar logic in Kitty and Foot.
//! The primary drawing code was originally ported directly and slightly
//! modified from Foot (https://codeberg.org/dnkl/foot/). Foot is licensed
//! under the MIT license and is copyright 2019 Daniel Eklöf.
//!
//! The modifications made were primarily around spacing, DPI calculations,
//! and adapting the code to our atlas model. Further, more extensive changes
//! were made, refactoring the line characters to all share a single unified
//! function (draw_lines), as well as many of the fractional block characters
//! which now use draw_block instead of dedicated separate functions.
//!
//! Additional characters from Unicode 16.0 and beyond are original work.
const Box = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const z2d = @import("z2d");

const font = @import("../main.zig");
const Sprite = @import("../sprite.zig").Sprite;

const log = std.log.scoped(.box_font);

/// Grid metrics for the rendering.
metrics: font.Metrics,

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

/// Specification of a traditional intersection-style line/box-drawing char,
/// which can have a different style of line from each edge to the center.
const Lines = packed struct(u8) {
    up: Style = .none,
    right: Style = .none,
    down: Style = .none,
    left: Style = .none,

    const Style = enum(u2) {
        none,
        light,
        heavy,
        double,
    };
};

/// Specification of a quadrants char, which has each of the
/// 4 quadrants of the character cell either filled or empty.
const Quads = packed struct(u4) {
    tl: bool = false,
    tr: bool = false,
    bl: bool = false,
    br: bool = false,
};

/// Specification of a branch drawing node, which consists of a
/// circle which is either empty or filled, and lines connecting
/// optionally between the circle and each of the 4 edges.
const BranchNode = packed struct(u5) {
    up: bool = false,
    right: bool = false,
    down: bool = false,
    left: bool = false,
    filled: bool = false,
};

/// Alignment of a figure within a cell
const Alignment = struct {
    horizontal: enum {
        left,
        right,
        center,
    } = .center,

    vertical: enum {
        top,
        bottom,
        middle,
    } = .middle,

    const upper: Alignment = .{ .vertical = .top };
    const lower: Alignment = .{ .vertical = .bottom };
    const left: Alignment = .{ .horizontal = .left };
    const right: Alignment = .{ .horizontal = .right };

    const upper_left: Alignment = .{ .vertical = .top, .horizontal = .left };
    const upper_right: Alignment = .{ .vertical = .top, .horizontal = .right };
    const lower_left: Alignment = .{ .vertical = .bottom, .horizontal = .left };
    const lower_right: Alignment = .{ .vertical = .bottom, .horizontal = .right };

    const center: Alignment = .{};

    const upper_center = upper;
    const lower_center = lower;
    const middle_left = left;
    const middle_right = right;
    const middle_center: Alignment = center;

    const top = upper;
    const bottom = lower;
    const center_top = top;
    const center_bottom = bottom;

    const top_left = upper_left;
    const top_right = upper_right;
    const bottom_left = lower_left;
    const bottom_right = lower_right;
};

const Corner = enum(u2) {
    tl,
    tr,
    bl,
    br,
};

const Edge = enum(u2) {
    top,
    left,
    bottom,
    right,
};

const SmoothMosaic = packed struct(u10) {
    tl: bool,
    ul: bool,
    ll: bool,
    bl: bool,
    bc: bool,
    br: bool,
    lr: bool,
    ur: bool,
    tr: bool,
    tc: bool,

    fn from(comptime pattern: *const [15:0]u8) SmoothMosaic {
        return .{
            .tl = pattern[0] == '#',

            .ul = pattern[4] == '#' and
                (pattern[0] != '#' or pattern[8] != '#'),

            .ll = pattern[8] == '#' and
                (pattern[4] != '#' or pattern[12] != '#'),

            .bl = pattern[12] == '#',

            .bc = pattern[13] == '#' and
                (pattern[12] != '#' or pattern[14] != '#'),

            .br = pattern[14] == '#',

            .lr = pattern[10] == '#' and
                (pattern[14] != '#' or pattern[6] != '#'),

            .ur = pattern[6] == '#' and
                (pattern[10] != '#' or pattern[2] != '#'),

            .tr = pattern[2] == '#',

            .tc = pattern[1] == '#' and
                (pattern[2] != '#' or pattern[0] != '#'),
        };
    }
};

// Octant range, inclusive
const octant_min = 0x1cd00;
const octant_max = 0x1cde5;

// Utility names for common fractions
const one_eighth: f64 = 0.125;
const one_quarter: f64 = 0.25;
const one_third: f64 = (1.0 / 3.0);
const three_eighths: f64 = 0.375;
const half: f64 = 0.5;
const five_eighths: f64 = 0.625;
const two_thirds: f64 = (2.0 / 3.0);
const three_quarters: f64 = 0.75;
const seven_eighths: f64 = 0.875;

/// Shades
const Shade = enum(u8) {
    off = 0x00,
    light = 0x40,
    medium = 0x80,
    dark = 0xc0,
    on = 0xff,

    _,
};

pub fn renderGlyph(
    self: Box,
    alloc: Allocator,
    atlas: *font.Atlas,
    cp: u32,
) !font.Glyph {
    const metrics = self.metrics;

    // Create the canvas we'll use to draw
    var canvas = try font.sprite.Canvas.init(
        alloc,
        metrics.cell_width,
        metrics.cell_height,
    );
    defer canvas.deinit();

    // Perform the actual drawing
    try self.draw(alloc, &canvas, cp);

    // Write the drawing to the atlas
    const region = try canvas.writeAtlas(alloc, atlas);

    // Our coordinates start at the BOTTOM for our renderers so we have to
    // specify an offset of the full height because we rendered a full size
    // cell.
    const offset_y = @as(i32, @intCast(metrics.cell_height));

    return font.Glyph{
        .width = metrics.cell_width,
        .height = metrics.cell_height,
        .offset_x = 0,
        .offset_y = offset_y,
        .atlas_x = region.x,
        .atlas_y = region.y,
        .advance_x = @floatFromInt(metrics.cell_width),
    };
}

fn draw(self: Box, alloc: Allocator, canvas: *font.sprite.Canvas, cp: u32) !void {
    _ = alloc;
    switch (cp) {
        // '─'
        0x2500 => self.draw_lines(canvas, .{ .left = .light, .right = .light }),
        // '━'
        0x2501 => self.draw_lines(canvas, .{ .left = .heavy, .right = .heavy }),
        // '│'
        0x2502 => self.draw_lines(canvas, .{ .up = .light, .down = .light }),
        // '┃'
        0x2503 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy }),
        // '┄'
        0x2504 => self.draw_light_triple_dash_horizontal(canvas),
        // '┅'
        0x2505 => self.draw_heavy_triple_dash_horizontal(canvas),
        // '┆'
        0x2506 => self.draw_light_triple_dash_vertical(canvas),
        // '┇'
        0x2507 => self.draw_heavy_triple_dash_vertical(canvas),
        // '┈'
        0x2508 => self.draw_light_quadruple_dash_horizontal(canvas),
        // '┉'
        0x2509 => self.draw_heavy_quadruple_dash_horizontal(canvas),
        // '┊'
        0x250a => self.draw_light_quadruple_dash_vertical(canvas),
        // '┋'
        0x250b => self.draw_heavy_quadruple_dash_vertical(canvas),
        // '┌'
        0x250c => self.draw_lines(canvas, .{ .down = .light, .right = .light }),
        // '┍'
        0x250d => self.draw_lines(canvas, .{ .down = .light, .right = .heavy }),
        // '┎'
        0x250e => self.draw_lines(canvas, .{ .down = .heavy, .right = .light }),
        // '┏'
        0x250f => self.draw_lines(canvas, .{ .down = .heavy, .right = .heavy }),

        // '┐'
        0x2510 => self.draw_lines(canvas, .{ .down = .light, .left = .light }),
        // '┑'
        0x2511 => self.draw_lines(canvas, .{ .down = .light, .left = .heavy }),
        // '┒'
        0x2512 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light }),
        // '┓'
        0x2513 => self.draw_lines(canvas, .{ .down = .heavy, .left = .heavy }),
        // '└'
        0x2514 => self.draw_lines(canvas, .{ .up = .light, .right = .light }),
        // '┕'
        0x2515 => self.draw_lines(canvas, .{ .up = .light, .right = .heavy }),
        // '┖'
        0x2516 => self.draw_lines(canvas, .{ .up = .heavy, .right = .light }),
        // '┗'
        0x2517 => self.draw_lines(canvas, .{ .up = .heavy, .right = .heavy }),
        // '┘'
        0x2518 => self.draw_lines(canvas, .{ .up = .light, .left = .light }),
        // '┙'
        0x2519 => self.draw_lines(canvas, .{ .up = .light, .left = .heavy }),
        // '┚'
        0x251a => self.draw_lines(canvas, .{ .up = .heavy, .left = .light }),
        // '┛'
        0x251b => self.draw_lines(canvas, .{ .up = .heavy, .left = .heavy }),
        // '├'
        0x251c => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .light }),
        // '┝'
        0x251d => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .heavy }),
        // '┞'
        0x251e => self.draw_lines(canvas, .{ .up = .heavy, .right = .light, .down = .light }),
        // '┟'
        0x251f => self.draw_lines(canvas, .{ .down = .heavy, .right = .light, .up = .light }),

        // '┠'
        0x2520 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .right = .light }),
        // '┡'
        0x2521 => self.draw_lines(canvas, .{ .down = .light, .right = .heavy, .up = .heavy }),
        // '┢'
        0x2522 => self.draw_lines(canvas, .{ .up = .light, .right = .heavy, .down = .heavy }),
        // '┣'
        0x2523 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .right = .heavy }),
        // '┤'
        0x2524 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .light }),
        // '┥'
        0x2525 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .heavy }),
        // '┦'
        0x2526 => self.draw_lines(canvas, .{ .up = .heavy, .left = .light, .down = .light }),
        // '┧'
        0x2527 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light, .up = .light }),
        // '┨'
        0x2528 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .light }),
        // '┩'
        0x2529 => self.draw_lines(canvas, .{ .down = .light, .left = .heavy, .up = .heavy }),
        // '┪'
        0x252a => self.draw_lines(canvas, .{ .up = .light, .left = .heavy, .down = .heavy }),
        // '┫'
        0x252b => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy }),
        // '┬'
        0x252c => self.draw_lines(canvas, .{ .down = .light, .left = .light, .right = .light }),
        // '┭'
        0x252d => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .down = .light }),
        // '┮'
        0x252e => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .down = .light }),
        // '┯'
        0x252f => self.draw_lines(canvas, .{ .down = .light, .left = .heavy, .right = .heavy }),

        // '┰'
        0x2530 => self.draw_lines(canvas, .{ .down = .heavy, .left = .light, .right = .light }),
        // '┱'
        0x2531 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .down = .heavy }),
        // '┲'
        0x2532 => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .down = .heavy }),
        // '┳'
        0x2533 => self.draw_lines(canvas, .{ .down = .heavy, .left = .heavy, .right = .heavy }),
        // '┴'
        0x2534 => self.draw_lines(canvas, .{ .up = .light, .left = .light, .right = .light }),
        // '┵'
        0x2535 => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .up = .light }),
        // '┶'
        0x2536 => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .up = .light }),
        // '┷'
        0x2537 => self.draw_lines(canvas, .{ .up = .light, .left = .heavy, .right = .heavy }),
        // '┸'
        0x2538 => self.draw_lines(canvas, .{ .up = .heavy, .left = .light, .right = .light }),
        // '┹'
        0x2539 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .up = .heavy }),
        // '┺'
        0x253a => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .up = .heavy }),
        // '┻'
        0x253b => self.draw_lines(canvas, .{ .up = .heavy, .left = .heavy, .right = .heavy }),
        // '┼'
        0x253c => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .light, .right = .light }),
        // '┽'
        0x253d => self.draw_lines(canvas, .{ .left = .heavy, .right = .light, .up = .light, .down = .light }),
        // '┾'
        0x253e => self.draw_lines(canvas, .{ .right = .heavy, .left = .light, .up = .light, .down = .light }),
        // '┿'
        0x253f => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .heavy, .right = .heavy }),

        // '╀'
        0x2540 => self.draw_lines(canvas, .{ .up = .heavy, .down = .light, .left = .light, .right = .light }),
        // '╁'
        0x2541 => self.draw_lines(canvas, .{ .down = .heavy, .up = .light, .left = .light, .right = .light }),
        // '╂'
        0x2542 => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),
        // '╃'
        0x2543 => self.draw_lines(canvas, .{ .left = .heavy, .up = .heavy, .right = .light, .down = .light }),
        // '╄'
        0x2544 => self.draw_lines(canvas, .{ .right = .heavy, .up = .heavy, .left = .light, .down = .light }),
        // '╅'
        0x2545 => self.draw_lines(canvas, .{ .left = .heavy, .down = .heavy, .right = .light, .up = .light }),
        // '╆'
        0x2546 => self.draw_lines(canvas, .{ .right = .heavy, .down = .heavy, .left = .light, .up = .light }),
        // '╇'
        0x2547 => self.draw_lines(canvas, .{ .down = .light, .up = .heavy, .left = .heavy, .right = .heavy }),
        // '╈'
        0x2548 => self.draw_lines(canvas, .{ .up = .light, .down = .heavy, .left = .heavy, .right = .heavy }),
        // '╉'
        0x2549 => self.draw_lines(canvas, .{ .right = .light, .left = .heavy, .up = .heavy, .down = .heavy }),
        // '╊'
        0x254a => self.draw_lines(canvas, .{ .left = .light, .right = .heavy, .up = .heavy, .down = .heavy }),
        // '╋'
        0x254b => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .heavy, .right = .heavy }),
        // '╌'
        0x254c => self.draw_light_double_dash_horizontal(canvas),
        // '╍'
        0x254d => self.draw_heavy_double_dash_horizontal(canvas),
        // '╎'
        0x254e => self.draw_light_double_dash_vertical(canvas),
        // '╏'
        0x254f => self.draw_heavy_double_dash_vertical(canvas),

        // '═'
        0x2550 => self.draw_lines(canvas, .{ .left = .double, .right = .double }),
        // '║'
        0x2551 => self.draw_lines(canvas, .{ .up = .double, .down = .double }),
        // '╒'
        0x2552 => self.draw_lines(canvas, .{ .down = .light, .right = .double }),
        // '╓'
        0x2553 => self.draw_lines(canvas, .{ .down = .double, .right = .light }),
        // '╔'
        0x2554 => self.draw_lines(canvas, .{ .down = .double, .right = .double }),
        // '╕'
        0x2555 => self.draw_lines(canvas, .{ .down = .light, .left = .double }),
        // '╖'
        0x2556 => self.draw_lines(canvas, .{ .down = .double, .left = .light }),
        // '╗'
        0x2557 => self.draw_lines(canvas, .{ .down = .double, .left = .double }),
        // '╘'
        0x2558 => self.draw_lines(canvas, .{ .up = .light, .right = .double }),
        // '╙'
        0x2559 => self.draw_lines(canvas, .{ .up = .double, .right = .light }),
        // '╚'
        0x255a => self.draw_lines(canvas, .{ .up = .double, .right = .double }),
        // '╛'
        0x255b => self.draw_lines(canvas, .{ .up = .light, .left = .double }),
        // '╜'
        0x255c => self.draw_lines(canvas, .{ .up = .double, .left = .light }),
        // '╝'
        0x255d => self.draw_lines(canvas, .{ .up = .double, .left = .double }),
        // '╞'
        0x255e => self.draw_lines(canvas, .{ .up = .light, .down = .light, .right = .double }),
        // '╟'
        0x255f => self.draw_lines(canvas, .{ .up = .double, .down = .double, .right = .light }),

        // '╠'
        0x2560 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .right = .double }),
        // '╡'
        0x2561 => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .double }),
        // '╢'
        0x2562 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .light }),
        // '╣'
        0x2563 => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .double }),
        // '╤'
        0x2564 => self.draw_lines(canvas, .{ .down = .light, .left = .double, .right = .double }),
        // '╥'
        0x2565 => self.draw_lines(canvas, .{ .down = .double, .left = .light, .right = .light }),
        // '╦'
        0x2566 => self.draw_lines(canvas, .{ .down = .double, .left = .double, .right = .double }),
        // '╧'
        0x2567 => self.draw_lines(canvas, .{ .up = .light, .left = .double, .right = .double }),
        // '╨'
        0x2568 => self.draw_lines(canvas, .{ .up = .double, .left = .light, .right = .light }),
        // '╩'
        0x2569 => self.draw_lines(canvas, .{ .up = .double, .left = .double, .right = .double }),
        // '╪'
        0x256a => self.draw_lines(canvas, .{ .up = .light, .down = .light, .left = .double, .right = .double }),
        // '╫'
        0x256b => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .light, .right = .light }),
        // '╬'
        0x256c => self.draw_lines(canvas, .{ .up = .double, .down = .double, .left = .double, .right = .double }),
        // '╭'
        0x256d => try self.draw_arc(canvas, .br, .light),
        // '╮'
        0x256e => try self.draw_arc(canvas, .bl, .light),
        // '╯'
        0x256f => try self.draw_arc(canvas, .tl, .light),

        // '╰'
        0x2570 => try self.draw_arc(canvas, .tr, .light),
        // '╱'
        0x2571 => self.draw_light_diagonal_upper_right_to_lower_left(canvas),
        // '╲'
        0x2572 => self.draw_light_diagonal_upper_left_to_lower_right(canvas),
        // '╳'
        0x2573 => self.draw_light_diagonal_cross(canvas),
        // '╴'
        0x2574 => self.draw_lines(canvas, .{ .left = .light }),
        // '╵'
        0x2575 => self.draw_lines(canvas, .{ .up = .light }),
        // '╶'
        0x2576 => self.draw_lines(canvas, .{ .right = .light }),
        // '╷'
        0x2577 => self.draw_lines(canvas, .{ .down = .light }),
        // '╸'
        0x2578 => self.draw_lines(canvas, .{ .left = .heavy }),
        // '╹'
        0x2579 => self.draw_lines(canvas, .{ .up = .heavy }),
        // '╺'
        0x257a => self.draw_lines(canvas, .{ .right = .heavy }),
        // '╻'
        0x257b => self.draw_lines(canvas, .{ .down = .heavy }),
        // '╼'
        0x257c => self.draw_lines(canvas, .{ .left = .light, .right = .heavy }),
        // '╽'
        0x257d => self.draw_lines(canvas, .{ .up = .light, .down = .heavy }),
        // '╾'
        0x257e => self.draw_lines(canvas, .{ .left = .heavy, .right = .light }),
        // '╿'
        0x257f => self.draw_lines(canvas, .{ .up = .heavy, .down = .light }),

        // '▀' UPPER HALF BLOCK
        0x2580 => self.draw_block(canvas, Alignment.upper, 1, half),
        // '▁' LOWER ONE EIGHTH BLOCK
        0x2581 => self.draw_block(canvas, Alignment.lower, 1, one_eighth),
        // '▂' LOWER ONE QUARTER BLOCK
        0x2582 => self.draw_block(canvas, Alignment.lower, 1, one_quarter),
        // '▃' LOWER THREE EIGHTHS BLOCK
        0x2583 => self.draw_block(canvas, Alignment.lower, 1, three_eighths),
        // '▄' LOWER HALF BLOCK
        0x2584 => self.draw_block(canvas, Alignment.lower, 1, half),
        // '▅' LOWER FIVE EIGHTHS BLOCK
        0x2585 => self.draw_block(canvas, Alignment.lower, 1, five_eighths),
        // '▆' LOWER THREE QUARTERS BLOCK
        0x2586 => self.draw_block(canvas, Alignment.lower, 1, three_quarters),
        // '▇' LOWER SEVEN EIGHTHS BLOCK
        0x2587 => self.draw_block(canvas, Alignment.lower, 1, seven_eighths),
        // '█' FULL BLOCK
        0x2588 => self.draw_full_block(canvas),
        // '▉' LEFT SEVEN EIGHTHS BLOCK
        0x2589 => self.draw_block(canvas, Alignment.left, seven_eighths, 1),
        // '▊' LEFT THREE QUARTERS BLOCK
        0x258a => self.draw_block(canvas, Alignment.left, three_quarters, 1),
        // '▋' LEFT FIVE EIGHTHS BLOCK
        0x258b => self.draw_block(canvas, Alignment.left, five_eighths, 1),
        // '▌' LEFT HALF BLOCK
        0x258c => self.draw_block(canvas, Alignment.left, half, 1),
        // '▍' LEFT THREE EIGHTHS BLOCK
        0x258d => self.draw_block(canvas, Alignment.left, three_eighths, 1),
        // '▎' LEFT ONE QUARTER BLOCK
        0x258e => self.draw_block(canvas, Alignment.left, one_quarter, 1),
        // '▏' LEFT ONE EIGHTH BLOCK
        0x258f => self.draw_block(canvas, Alignment.left, one_eighth, 1),

        // '▐' RIGHT HALF BLOCK
        0x2590 => self.draw_block(canvas, Alignment.right, half, 1),
        // '░'
        0x2591 => self.draw_light_shade(canvas),
        // '▒'
        0x2592 => self.draw_medium_shade(canvas),
        // '▓'
        0x2593 => self.draw_dark_shade(canvas),
        // '▔' UPPER ONE EIGHTH BLOCK
        0x2594 => self.draw_block(canvas, Alignment.upper, 1, one_eighth),
        // '▕' RIGHT ONE EIGHTH BLOCK
        0x2595 => self.draw_block(canvas, Alignment.right, one_eighth, 1),
        // '▖'
        0x2596 => self.draw_quadrant(canvas, .{ .bl = true }),
        // '▗'
        0x2597 => self.draw_quadrant(canvas, .{ .br = true }),
        // '▘'
        0x2598 => self.draw_quadrant(canvas, .{ .tl = true }),
        // '▙'
        0x2599 => self.draw_quadrant(canvas, .{ .tl = true, .bl = true, .br = true }),
        // '▚'
        0x259a => self.draw_quadrant(canvas, .{ .tl = true, .br = true }),
        // '▛'
        0x259b => self.draw_quadrant(canvas, .{ .tl = true, .tr = true, .bl = true }),
        // '▜'
        0x259c => self.draw_quadrant(canvas, .{ .tl = true, .tr = true, .br = true }),
        // '▝'
        0x259d => self.draw_quadrant(canvas, .{ .tr = true }),
        // '▞'
        0x259e => self.draw_quadrant(canvas, .{ .tr = true, .bl = true }),
        // '▟'
        0x259f => self.draw_quadrant(canvas, .{ .tr = true, .bl = true, .br = true }),

        0x2800...0x28ff => self.draw_braille(canvas, cp),

        0x1fb00...0x1fb3b => self.draw_sextant(canvas, cp),

        octant_min...octant_max => self.draw_octant(canvas, cp),

        // '🬼'
        0x1fb3c => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\...
            \\#..
            \\##.
        )),
        // '🬽'
        0x1fb3d => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\...
            \\#\.
            \\###
        )),
        // '🬾'
        0x1fb3e => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\#..
            \\#\.
            \\##.
        )),
        // '🬿'
        0x1fb3f => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\#..
            \\##.
            \\###
        )),
        // '🭀'
        0x1fb40 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\#..
            \\#..
            \\##.
            \\##.
        )),

        // '🭁'
        0x1fb41 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\/##
            \\###
            \\###
            \\###
        )),
        // '🭂'
        0x1fb42 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\./#
            \\###
            \\###
            \\###
        )),
        // '🭃'
        0x1fb43 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\.##
            \\.##
            \\###
            \\###
        )),
        // '🭄'
        0x1fb44 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\..#
            \\.##
            \\###
            \\###
        )),
        // '🭅'
        0x1fb45 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\.##
            \\.##
            \\.##
            \\###
        )),
        // '🭆'
        0x1fb46 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\./#
            \\###
            \\###
        )),

        // '🭇'
        0x1fb47 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\...
            \\..#
            \\.##
        )),
        // '🭈'
        0x1fb48 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\...
            \\./#
            \\###
        )),
        // '🭉'
        0x1fb49 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\..#
            \\./#
            \\.##
        )),
        // '🭊'
        0x1fb4a => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\..#
            \\.##
            \\###
        )),
        // '🭋'
        0x1fb4b => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\..#
            \\..#
            \\.##
            \\.##
        )),

        // '🭌'
        0x1fb4c => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##\
            \\###
            \\###
            \\###
        )),
        // '🭍'
        0x1fb4d => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\#\.
            \\###
            \\###
            \\###
        )),
        // '🭎'
        0x1fb4e => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##.
            \\##.
            \\###
            \\###
        )),
        // '🭏'
        0x1fb4f => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\#..
            \\##.
            \\###
            \\###
        )),
        // '🭐'
        0x1fb50 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##.
            \\##.
            \\##.
            \\###
        )),
        // '🭑'
        0x1fb51 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\...
            \\#\.
            \\###
            \\###
        )),

        // '🭒'
        0x1fb52 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\\##
        )),
        // '🭓'
        0x1fb53 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\.\#
        )),
        // '🭔'
        0x1fb54 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\.##
            \\.##
        )),
        // '🭕'
        0x1fb55 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\.##
            \\..#
        )),
        // '🭖'
        0x1fb56 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\.##
            \\.##
            \\.##
        )),

        // '🭗'
        0x1fb57 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##.
            \\#..
            \\...
            \\...
        )),
        // '🭘'
        0x1fb58 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\#/.
            \\...
            \\...
        )),
        // '🭙'
        0x1fb59 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##.
            \\#/.
            \\#..
            \\...
        )),
        // '🭚'
        0x1fb5a => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\##.
            \\#..
            \\...
        )),
        // '🭛'
        0x1fb5b => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\##.
            \\##.
            \\#..
            \\#..
        )),

        // '🭜'
        0x1fb5c => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\#/.
            \\...
        )),
        // '🭝'
        0x1fb5d => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\##/
        )),
        // '🭞'
        0x1fb5e => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\###
            \\#/.
        )),
        // '🭟'
        0x1fb5f => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\##.
            \\##.
        )),
        // '🭠'
        0x1fb60 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\##.
            \\#..
        )),
        // '🭡'
        0x1fb61 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\##.
            \\##.
            \\##.
        )),

        // '🭢'
        0x1fb62 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\.##
            \\..#
            \\...
            \\...
        )),
        // '🭣'
        0x1fb63 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\.\#
            \\...
            \\...
        )),
        // '🭤'
        0x1fb64 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\.##
            \\.\#
            \\..#
            \\...
        )),
        // '🭥'
        0x1fb65 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\.##
            \\..#
            \\...
        )),
        // '🭦'
        0x1fb66 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\.##
            \\.##
            \\..#
            \\..#
        )),
        // '🭧'
        0x1fb67 => try self.draw_smooth_mosaic(canvas, SmoothMosaic.from(
            \\###
            \\###
            \\.\#
            \\...
        )),

        // '🭨'
        0x1fb68 => {
            try self.draw_edge_triangle(canvas, .left);
            canvas.invert();
        },
        // '🭩'
        0x1fb69 => {
            try self.draw_edge_triangle(canvas, .top);
            canvas.invert();
        },
        // '🭪'
        0x1fb6a => {
            try self.draw_edge_triangle(canvas, .right);
            canvas.invert();
        },
        // '🭫'
        0x1fb6b => {
            try self.draw_edge_triangle(canvas, .bottom);
            canvas.invert();
        },
        // '🭬'
        0x1fb6c => try self.draw_edge_triangle(canvas, .left),
        // '🭭'
        0x1fb6d => try self.draw_edge_triangle(canvas, .top),
        // '🭮'
        0x1fb6e => try self.draw_edge_triangle(canvas, .right),
        // '🭯'
        0x1fb6f => try self.draw_edge_triangle(canvas, .bottom),

        // '🭰'
        0x1fb70 => self.draw_vertical_one_eighth_block_n(canvas, 1),
        // '🭱'
        0x1fb71 => self.draw_vertical_one_eighth_block_n(canvas, 2),
        // '🭲'
        0x1fb72 => self.draw_vertical_one_eighth_block_n(canvas, 3),
        // '🭳'
        0x1fb73 => self.draw_vertical_one_eighth_block_n(canvas, 4),
        // '🭴'
        0x1fb74 => self.draw_vertical_one_eighth_block_n(canvas, 5),
        // '🭵'
        0x1fb75 => self.draw_vertical_one_eighth_block_n(canvas, 6),

        // '🭶'
        0x1fb76 => self.draw_horizontal_one_eighth_block_n(canvas, 1),
        // '🭷'
        0x1fb77 => self.draw_horizontal_one_eighth_block_n(canvas, 2),
        // '🭸'
        0x1fb78 => self.draw_horizontal_one_eighth_block_n(canvas, 3),
        // '🭹'
        0x1fb79 => self.draw_horizontal_one_eighth_block_n(canvas, 4),
        // '🭺'
        0x1fb7a => self.draw_horizontal_one_eighth_block_n(canvas, 5),
        // '🭻'
        0x1fb7b => self.draw_horizontal_one_eighth_block_n(canvas, 6),

        // '🮂' UPPER ONE QUARTER BLOCK
        0x1fb82 => self.draw_block(canvas, Alignment.upper, 1, one_quarter),
        // '🮃' UPPER THREE EIGHTHS BLOCK
        0x1fb83 => self.draw_block(canvas, Alignment.upper, 1, three_eighths),
        // '🮄' UPPER FIVE EIGHTHS BLOCK
        0x1fb84 => self.draw_block(canvas, Alignment.upper, 1, five_eighths),
        // '🮅' UPPER THREE QUARTERS BLOCK
        0x1fb85 => self.draw_block(canvas, Alignment.upper, 1, three_quarters),
        // '🮆' UPPER SEVEN EIGHTHS BLOCK
        0x1fb86 => self.draw_block(canvas, Alignment.upper, 1, seven_eighths),

        // '🭼' LEFT AND LOWER ONE EIGHTH BLOCK
        0x1fb7c => {
            self.draw_block(canvas, Alignment.left, one_eighth, 1);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🭽' LEFT AND UPPER ONE EIGHTH BLOCK
        0x1fb7d => {
            self.draw_block(canvas, Alignment.left, one_eighth, 1);
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
        },
        // '🭾' RIGHT AND UPPER ONE EIGHTH BLOCK
        0x1fb7e => {
            self.draw_block(canvas, Alignment.right, one_eighth, 1);
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
        },
        // '🭿' RIGHT AND LOWER ONE EIGHTH BLOCK
        0x1fb7f => {
            self.draw_block(canvas, Alignment.right, one_eighth, 1);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🮀' UPPER AND LOWER ONE EIGHTH BLOCK
        0x1fb80 => {
            self.draw_block(canvas, Alignment.upper, 1, one_eighth);
            self.draw_block(canvas, Alignment.lower, 1, one_eighth);
        },
        // '🮁'
        0x1fb81 => self.draw_horizontal_one_eighth_1358_block(canvas),

        // '🮇' RIGHT ONE QUARTER BLOCK
        0x1fb87 => self.draw_block(canvas, Alignment.right, one_quarter, 1),
        // '🮈' RIGHT THREE EIGHTHS BLOCK
        0x1fb88 => self.draw_block(canvas, Alignment.right, three_eighths, 1),
        // '🮉' RIGHT FIVE EIGHTHS BLOCK
        0x1fb89 => self.draw_block(canvas, Alignment.right, five_eighths, 1),
        // '🮊' RIGHT THREE QUARTERS BLOCK
        0x1fb8a => self.draw_block(canvas, Alignment.right, three_quarters, 1),
        // '🮋' RIGHT SEVEN EIGHTHS BLOCK
        0x1fb8b => self.draw_block(canvas, Alignment.right, seven_eighths, 1),
        // '🮌'
        0x1fb8c => self.draw_block_shade(canvas, Alignment.left, half, 1, .medium),
        // '🮍'
        0x1fb8d => self.draw_block_shade(canvas, Alignment.right, half, 1, .medium),
        // '🮎'
        0x1fb8e => self.draw_block_shade(canvas, Alignment.upper, 1, half, .medium),
        // '🮏'
        0x1fb8f => self.draw_block_shade(canvas, Alignment.lower, 1, half, .medium),

        // '🮐'
        0x1fb90 => self.draw_medium_shade(canvas),
        // '🮑'
        0x1fb91 => {
            self.draw_medium_shade(canvas);
            self.draw_block(canvas, Alignment.upper, 1, half);
        },
        // '🮒'
        0x1fb92 => {
            self.draw_medium_shade(canvas);
            self.draw_block(canvas, Alignment.lower, 1, half);
        },
        // '🮔'
        0x1fb94 => {
            self.draw_medium_shade(canvas);
            self.draw_block(canvas, Alignment.right, half, 1);
        },
        // '🮕'
        0x1fb95 => self.draw_checkerboard_fill(canvas, 0),
        // '🮖'
        0x1fb96 => self.draw_checkerboard_fill(canvas, 1),
        // '🮗'
        0x1fb97 => {
            self.draw_horizontal_one_eighth_block_n(canvas, 2);
            self.draw_horizontal_one_eighth_block_n(canvas, 3);
            self.draw_horizontal_one_eighth_block_n(canvas, 6);
            self.draw_horizontal_one_eighth_block_n(canvas, 7);
        },
        // '🮘'
        0x1fb98 => self.draw_upper_left_to_lower_right_fill(canvas),
        // '🮙'
        0x1fb99 => self.draw_upper_right_to_lower_left_fill(canvas),
        // '🮚'
        0x1fb9a => {
            try self.draw_edge_triangle(canvas, .top);
            try self.draw_edge_triangle(canvas, .bottom);
        },
        // '🮛'
        0x1fb9b => {
            try self.draw_edge_triangle(canvas, .left);
            try self.draw_edge_triangle(canvas, .right);
        },
        // '🮜'
        0x1fb9c => self.draw_corner_triangle_shade(canvas, .tl, .medium),
        // '🮝'
        0x1fb9d => self.draw_corner_triangle_shade(canvas, .tr, .medium),
        // '🮞'
        0x1fb9e => self.draw_corner_triangle_shade(canvas, .br, .medium),
        // '🮟'
        0x1fb9f => self.draw_corner_triangle_shade(canvas, .bl, .medium),

        // '🮠'
        0x1fba0 => self.draw_corner_diagonal_lines(canvas, .{ .tl = true }),
        // '🮡'
        0x1fba1 => self.draw_corner_diagonal_lines(canvas, .{ .tr = true }),
        // '🮢'
        0x1fba2 => self.draw_corner_diagonal_lines(canvas, .{ .bl = true }),
        // '🮣'
        0x1fba3 => self.draw_corner_diagonal_lines(canvas, .{ .br = true }),
        // '🮤'
        0x1fba4 => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .bl = true }),
        // '🮥'
        0x1fba5 => self.draw_corner_diagonal_lines(canvas, .{ .tr = true, .br = true }),
        // '🮦'
        0x1fba6 => self.draw_corner_diagonal_lines(canvas, .{ .bl = true, .br = true }),
        // '🮧'
        0x1fba7 => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .tr = true }),
        // '🮨'
        0x1fba8 => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .br = true }),
        // '🮩'
        0x1fba9 => self.draw_corner_diagonal_lines(canvas, .{ .tr = true, .bl = true }),
        // '🮪'
        0x1fbaa => self.draw_corner_diagonal_lines(canvas, .{ .tr = true, .bl = true, .br = true }),
        // '🮫'
        0x1fbab => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .bl = true, .br = true }),
        // '🮬'
        0x1fbac => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .tr = true, .br = true }),
        // '🮭'
        0x1fbad => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .tr = true, .bl = true }),
        // '🮮'
        0x1fbae => self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .tr = true, .bl = true, .br = true }),
        // '🮯'
        0x1fbaf => self.draw_lines(canvas, .{ .up = .heavy, .down = .heavy, .left = .light, .right = .light }),

        // '🮽'
        0x1fbbd => {
            self.draw_light_diagonal_cross(canvas);
            canvas.invert();
        },
        // '🮾'
        0x1fbbe => {
            self.draw_corner_diagonal_lines(canvas, .{ .br = true });
            canvas.invert();
        },
        // '🮿'
        0x1fbbf => {
            self.draw_corner_diagonal_lines(canvas, .{ .tl = true, .tr = true, .bl = true, .br = true });
            canvas.invert();
        },

        // '🯎'
        0x1fbce => self.draw_block(canvas, Alignment.left, two_thirds, 1),
        // '🯏'
        0x1fbcf => self.draw_block(canvas, Alignment.left, one_third, 1),
        // '🯐'
        0x1fbd0 => self.draw_cell_diagonal(
            canvas,
            Alignment.middle_right,
            Alignment.lower_left,
        ),
        // '🯑'
        0x1fbd1 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_right,
            Alignment.middle_left,
        ),
        // '🯒'
        0x1fbd2 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_left,
            Alignment.middle_right,
        ),
        // '🯓'
        0x1fbd3 => self.draw_cell_diagonal(
            canvas,
            Alignment.middle_left,
            Alignment.lower_right,
        ),
        // '🯔'
        0x1fbd4 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_left,
            Alignment.lower_center,
        ),
        // '🯕'
        0x1fbd5 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_center,
            Alignment.lower_right,
        ),
        // '🯖'
        0x1fbd6 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_right,
            Alignment.lower_center,
        ),
        // '🯗'
        0x1fbd7 => self.draw_cell_diagonal(
            canvas,
            Alignment.upper_center,
            Alignment.lower_left,
        ),
        // '🯘'
        0x1fbd8 => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_left,
                Alignment.middle_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_center,
                Alignment.upper_right,
            );
        },
        // '🯙'
        0x1fbd9 => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_right,
                Alignment.middle_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_center,
                Alignment.lower_right,
            );
        },
        // '🯚'
        0x1fbda => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.lower_left,
                Alignment.middle_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_center,
                Alignment.lower_right,
            );
        },
        // '🯛'
        0x1fbdb => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_left,
                Alignment.middle_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_center,
                Alignment.lower_left,
            );
        },
        // '🯜'
        0x1fbdc => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_left,
                Alignment.lower_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.lower_center,
                Alignment.upper_right,
            );
        },
        // '🯝'
        0x1fbdd => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_right,
                Alignment.middle_left,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_left,
                Alignment.lower_right,
            );
        },
        // '🯞'
        0x1fbde => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.lower_left,
                Alignment.upper_center,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_center,
                Alignment.lower_right,
            );
        },
        // '🯟'
        0x1fbdf => {
            self.draw_cell_diagonal(
                canvas,
                Alignment.upper_left,
                Alignment.middle_right,
            );
            self.draw_cell_diagonal(
                canvas,
                Alignment.middle_right,
                Alignment.lower_left,
            );
        },

        // '🯠'
        0x1fbe0 => self.draw_circle(canvas, Alignment.top, false),
        // '🯡'
        0x1fbe1 => self.draw_circle(canvas, Alignment.right, false),
        // '🯢'
        0x1fbe2 => self.draw_circle(canvas, Alignment.bottom, false),
        // '🯣'
        0x1fbe3 => self.draw_circle(canvas, Alignment.left, false),
        // '🯤'
        0x1fbe4 => self.draw_block(canvas, Alignment.upper_center, 0.5, 0.5),
        // '🯥'
        0x1fbe5 => self.draw_block(canvas, Alignment.lower_center, 0.5, 0.5),
        // '🯦'
        0x1fbe6 => self.draw_block(canvas, Alignment.middle_left, 0.5, 0.5),
        // '🯧'
        0x1fbe7 => self.draw_block(canvas, Alignment.middle_right, 0.5, 0.5),
        // '🯨'
        0x1fbe8 => self.draw_circle(canvas, Alignment.top, true),
        // '🯩'
        0x1fbe9 => self.draw_circle(canvas, Alignment.right, true),
        // '🯪'
        0x1fbea => self.draw_circle(canvas, Alignment.bottom, true),
        // '🯫'
        0x1fbeb => self.draw_circle(canvas, Alignment.left, true),
        // '🯬'
        0x1fbec => self.draw_circle(canvas, Alignment.top_right, true),
        // '🯭'
        0x1fbed => self.draw_circle(canvas, Alignment.bottom_left, true),
        // '🯮'
        0x1fbee => self.draw_circle(canvas, Alignment.bottom_right, true),
        // '🯯'
        0x1fbef => self.draw_circle(canvas, Alignment.top_left, true),

        // (Below:)
        // Branch drawing character set, used for drawing git-like
        // graphs in the terminal. Originally implemented in Kitty.
        // Ref:
        // - https://github.com/kovidgoyal/kitty/pull/7681
        // - https://github.com/kovidgoyal/kitty/pull/7805
        // NOTE: Kitty is GPL licensed, and its code was not referenced
        //       for these characters, only the loose specification of
        //       the character set in the pull request descriptions.
        //
        // TODO(qwerasd): This should be in another file, but really the
        //                general organization of the sprite font code
        //                needs to be reworked eventually.
        //
        //          
        //                    
        //                    
        //            

        // ''
        0x0f5d0 => self.hline_middle(canvas, .light),
        // ''
        0x0f5d1 => self.vline_middle(canvas, .light),
        // ''
        0x0f5d2 => self.draw_fading_line(canvas, .right, .light),
        // ''
        0x0f5d3 => self.draw_fading_line(canvas, .left, .light),
        // ''
        0x0f5d4 => self.draw_fading_line(canvas, .bottom, .light),
        // ''
        0x0f5d5 => self.draw_fading_line(canvas, .top, .light),
        // ''
        0x0f5d6 => try self.draw_arc(canvas, .br, .light),
        // ''
        0x0f5d7 => try self.draw_arc(canvas, .bl, .light),
        // ''
        0x0f5d8 => try self.draw_arc(canvas, .tr, .light),
        // ''
        0x0f5d9 => try self.draw_arc(canvas, .tl, .light),
        // ''
        0x0f5da => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .tr, .light);
        },
        // ''
        0x0f5db => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5dc => {
            try self.draw_arc(canvas, .tr, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5dd => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .tl, .light);
        },
        // ''
        0x0f5de => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .bl, .light);
        },
        // ''
        0x0f5df => {
            try self.draw_arc(canvas, .tl, .light);
            try self.draw_arc(canvas, .bl, .light);
        },

        // ''
        0x0f5e0 => {
            try self.draw_arc(canvas, .bl, .light);
            self.hline_middle(canvas, .light);
        },
        // ''
        0x0f5e1 => {
            try self.draw_arc(canvas, .br, .light);
            self.hline_middle(canvas, .light);
        },
        // ''
        0x0f5e2 => {
            try self.draw_arc(canvas, .br, .light);
            try self.draw_arc(canvas, .bl, .light);
        },
        // ''
        0x0f5e3 => {
            try self.draw_arc(canvas, .tl, .light);
            self.hline_middle(canvas, .light);
        },
        // ''
        0x0f5e4 => {
            try self.draw_arc(canvas, .tr, .light);
            self.hline_middle(canvas, .light);
        },
        // ''
        0x0f5e5 => {
            try self.draw_arc(canvas, .tr, .light);
            try self.draw_arc(canvas, .tl, .light);
        },
        // ''
        0x0f5e6 => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .tl, .light);
            try self.draw_arc(canvas, .tr, .light);
        },
        // ''
        0x0f5e7 => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .bl, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5e8 => {
            self.hline_middle(canvas, .light);
            try self.draw_arc(canvas, .bl, .light);
            try self.draw_arc(canvas, .tl, .light);
        },
        // ''
        0x0f5e9 => {
            self.hline_middle(canvas, .light);
            try self.draw_arc(canvas, .tr, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5ea => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .tl, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5eb => {
            self.vline_middle(canvas, .light);
            try self.draw_arc(canvas, .tr, .light);
            try self.draw_arc(canvas, .bl, .light);
        },
        // ''
        0x0f5ec => {
            self.hline_middle(canvas, .light);
            try self.draw_arc(canvas, .tl, .light);
            try self.draw_arc(canvas, .br, .light);
        },
        // ''
        0x0f5ed => {
            self.hline_middle(canvas, .light);
            try self.draw_arc(canvas, .tr, .light);
            try self.draw_arc(canvas, .bl, .light);
        },
        // ''
        0x0f5ee => self.draw_branch_node(canvas, .{ .filled = true }, .light),
        // ''
        0x0f5ef => self.draw_branch_node(canvas, .{}, .light),

        // ''
        0x0f5f0 => self.draw_branch_node(canvas, .{
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5f1 => self.draw_branch_node(canvas, .{
            .right = true,
        }, .light),
        // ''
        0x0f5f2 => self.draw_branch_node(canvas, .{
            .left = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5f3 => self.draw_branch_node(canvas, .{
            .left = true,
        }, .light),
        // ''
        0x0f5f4 => self.draw_branch_node(canvas, .{
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5f5 => self.draw_branch_node(canvas, .{
            .left = true,
            .right = true,
        }, .light),
        // ''
        0x0f5f6 => self.draw_branch_node(canvas, .{
            .down = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5f7 => self.draw_branch_node(canvas, .{
            .down = true,
        }, .light),
        // ''
        0x0f5f8 => self.draw_branch_node(canvas, .{
            .up = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5f9 => self.draw_branch_node(canvas, .{
            .up = true,
        }, .light),
        // ''
        0x0f5fa => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5fb => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
        }, .light),
        // ''
        0x0f5fc => self.draw_branch_node(canvas, .{
            .right = true,
            .down = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5fd => self.draw_branch_node(canvas, .{
            .right = true,
            .down = true,
        }, .light),
        // ''
        0x0f5fe => self.draw_branch_node(canvas, .{
            .left = true,
            .down = true,
            .filled = true,
        }, .light),
        // ''
        0x0f5ff => self.draw_branch_node(canvas, .{
            .left = true,
            .down = true,
        }, .light),

        // ''
        0x0f600 => self.draw_branch_node(canvas, .{
            .up = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f601 => self.draw_branch_node(canvas, .{
            .up = true,
            .right = true,
        }, .light),
        // ''
        0x0f602 => self.draw_branch_node(canvas, .{
            .up = true,
            .left = true,
            .filled = true,
        }, .light),
        // ''
        0x0f603 => self.draw_branch_node(canvas, .{
            .up = true,
            .left = true,
        }, .light),
        // ''
        0x0f604 => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f605 => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .right = true,
        }, .light),
        // ''
        0x0f606 => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .filled = true,
        }, .light),
        // ''
        0x0f607 => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .left = true,
        }, .light),
        // ''
        0x0f608 => self.draw_branch_node(canvas, .{
            .down = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f609 => self.draw_branch_node(canvas, .{
            .down = true,
            .left = true,
            .right = true,
        }, .light),
        // ''
        0x0f60a => self.draw_branch_node(canvas, .{
            .up = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f60b => self.draw_branch_node(canvas, .{
            .up = true,
            .left = true,
            .right = true,
        }, .light),
        // ''
        0x0f60c => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .right = true,
            .filled = true,
        }, .light),
        // ''
        0x0f60d => self.draw_branch_node(canvas, .{
            .up = true,
            .down = true,
            .left = true,
            .right = true,
        }, .light),

        // '𜰡' - SEPARATED BLOCK QUADRANT-1
        0x1cc21 => try self.draw_separated_block_quadrant(canvas, "1"),
        // '𜰢' - SEPARATED BLOCK QUADRANT-2
        0x1cc22 => try self.draw_separated_block_quadrant(canvas, "2"),
        // '𜰣' - SEPARATED BLOCK QUADRANT-12
        0x1cc23 => try self.draw_separated_block_quadrant(canvas, "12"),
        // '𜰤' - SEPARATED BLOCK QUADRANT-3
        0x1cc24 => try self.draw_separated_block_quadrant(canvas, "3"),
        // '𜰥' - SEPARATED BLOCK QUADRANT-13
        0x1cc25 => try self.draw_separated_block_quadrant(canvas, "13"),
        // '𜰦' - SEPARATED BLOCK QUADRANT-23
        0x1cc26 => try self.draw_separated_block_quadrant(canvas, "23"),
        // '𜰧' - SEPARATED BLOCK QUADRANT-123
        0x1cc27 => try self.draw_separated_block_quadrant(canvas, "123"),
        // '𜰨' - SEPARATED BLOCK QUADRANT-4
        0x1cc28 => try self.draw_separated_block_quadrant(canvas, "4"),
        // '𜰩' - SEPARATED BLOCK QUADRANT-14
        0x1cc29 => try self.draw_separated_block_quadrant(canvas, "14"),
        // '𜰪' - SEPARATED BLOCK QUADRANT-24
        0x1cc2a => try self.draw_separated_block_quadrant(canvas, "24"),
        // '𜰫' - SEPARATED BLOCK QUADRANT-124
        0x1cc2b => try self.draw_separated_block_quadrant(canvas, "124"),
        // '𜰬' - SEPARATED BLOCK QUADRANT-34
        0x1cc2c => try self.draw_separated_block_quadrant(canvas, "34"),
        // '𜰭' - SEPARATED BLOCK QUADRANT-134
        0x1cc2d => try self.draw_separated_block_quadrant(canvas, "134"),
        // '𜰮' - SEPARATED BLOCK QUADRANT-234
        0x1cc2e => try self.draw_separated_block_quadrant(canvas, "234"),
        // '𜰯' - SEPARATED BLOCK QUADRANT-1234
        0x1cc2f => try self.draw_separated_block_quadrant(canvas, "1234"),

        else => return error.InvalidCodepoint,
    }
}

fn draw_lines(
    self: Box,
    canvas: *font.sprite.Canvas,
    lines: Lines,
) void {
    const light_px = Thickness.light.height(self.metrics.box_thickness);
    const heavy_px = Thickness.heavy.height(self.metrics.box_thickness);

    // Top of light horizontal strokes
    const h_light_top = (self.metrics.cell_height -| light_px) / 2;
    // Bottom of light horizontal strokes
    const h_light_bottom = h_light_top +| light_px;

    // Top of heavy horizontal strokes
    const h_heavy_top = (self.metrics.cell_height -| heavy_px) / 2;
    // Bottom of heavy horizontal strokes
    const h_heavy_bottom = h_heavy_top +| heavy_px;

    // Top of the top doubled horizontal stroke (bottom is `h_light_top`)
    const h_double_top = h_light_top -| light_px;
    // Bottom of the bottom doubled horizontal stroke (top is `h_light_bottom`)
    const h_double_bottom = h_light_bottom +| light_px;

    // Left of light vertical strokes
    const v_light_left = (self.metrics.cell_width -| light_px) / 2;
    // Right of light vertical strokes
    const v_light_right = v_light_left +| light_px;

    // Left of heavy vertical strokes
    const v_heavy_left = (self.metrics.cell_width -| heavy_px) / 2;
    // Right of heavy vertical strokes
    const v_heavy_right = v_heavy_left +| heavy_px;

    // Left of the left doubled vertical stroke (right is `v_light_left`)
    const v_double_left = v_light_left -| light_px;
    // Right of the right doubled vertical stroke (left is `v_light_right`)
    const v_double_right = v_light_right +| light_px;

    // The bottom of the up line
    const up_bottom = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_bottom
    else if (lines.left != lines.right or lines.down == lines.up)
        if (lines.left == .double or lines.right == .double)
            h_double_bottom
        else
            h_light_bottom
    else if (lines.left == .none and lines.right == .none)
        h_light_bottom
    else
        h_light_top;

    // The top of the down line
    const down_top = if (lines.left == .heavy or lines.right == .heavy)
        h_heavy_top
    else if (lines.left != lines.right or lines.up == lines.down)
        if (lines.left == .double or lines.right == .double)
            h_double_top
        else
            h_light_top
    else if (lines.left == .none and lines.right == .none)
        h_light_top
    else
        h_light_bottom;

    // The right of the left line
    const left_right = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_right
    else if (lines.up != lines.down or lines.left == lines.right)
        if (lines.up == .double or lines.down == .double)
            v_double_right
        else
            v_light_right
    else if (lines.up == .none and lines.down == .none)
        v_light_right
    else
        v_light_left;

    // The left of the right line
    const right_left = if (lines.up == .heavy or lines.down == .heavy)
        v_heavy_left
    else if (lines.up != lines.down or lines.right == lines.left)
        if (lines.up == .double or lines.down == .double)
            v_double_left
        else
            v_light_left
    else if (lines.up == .none and lines.down == .none)
        v_light_left
    else
        v_light_right;

    switch (lines.up) {
        .none => {},
        .light => self.rect(canvas, v_light_left, 0, v_light_right, up_bottom),
        .heavy => self.rect(canvas, v_heavy_left, 0, v_heavy_right, up_bottom),
        .double => {
            const left_bottom = if (lines.left == .double) h_light_top else up_bottom;
            const right_bottom = if (lines.right == .double) h_light_top else up_bottom;

            self.rect(canvas, v_double_left, 0, v_light_left, left_bottom);
            self.rect(canvas, v_light_right, 0, v_double_right, right_bottom);
        },
    }

    switch (lines.right) {
        .none => {},
        .light => self.rect(canvas, right_left, h_light_top, self.metrics.cell_width, h_light_bottom),
        .heavy => self.rect(canvas, right_left, h_heavy_top, self.metrics.cell_width, h_heavy_bottom),
        .double => {
            const top_left = if (lines.up == .double) v_light_right else right_left;
            const bottom_left = if (lines.down == .double) v_light_right else right_left;

            self.rect(canvas, top_left, h_double_top, self.metrics.cell_width, h_light_top);
            self.rect(canvas, bottom_left, h_light_bottom, self.metrics.cell_width, h_double_bottom);
        },
    }

    switch (lines.down) {
        .none => {},
        .light => self.rect(canvas, v_light_left, down_top, v_light_right, self.metrics.cell_height),
        .heavy => self.rect(canvas, v_heavy_left, down_top, v_heavy_right, self.metrics.cell_height),
        .double => {
            const left_top = if (lines.left == .double) h_light_bottom else down_top;
            const right_top = if (lines.right == .double) h_light_bottom else down_top;

            self.rect(canvas, v_double_left, left_top, v_light_left, self.metrics.cell_height);
            self.rect(canvas, v_light_right, right_top, v_double_right, self.metrics.cell_height);
        },
    }

    switch (lines.left) {
        .none => {},
        .light => self.rect(canvas, 0, h_light_top, left_right, h_light_bottom),
        .heavy => self.rect(canvas, 0, h_heavy_top, left_right, h_heavy_bottom),
        .double => {
            const top_right = if (lines.up == .double) v_light_left else left_right;
            const bottom_right = if (lines.down == .double) v_light_left else left_right;

            self.rect(canvas, 0, h_double_top, top_right, h_light_top);
            self.rect(canvas, 0, h_light_bottom, bottom_right, h_double_bottom);
        },
    }
}

fn draw_light_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.light.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_heavy_triple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        3,
        Thickness.heavy.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_light_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.light.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_heavy_triple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        3,
        Thickness.heavy.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_light_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.light.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_heavy_quadruple_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        4,
        Thickness.heavy.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_light_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.light.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_heavy_quadruple_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        4,
        Thickness.heavy.height(self.metrics.box_thickness),
        @max(4, Thickness.light.height(self.metrics.box_thickness)),
    );
}

fn draw_light_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.light.height(self.metrics.box_thickness),
        Thickness.light.height(self.metrics.box_thickness),
    );
}

fn draw_heavy_double_dash_horizontal(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_horizontal(
        canvas,
        2,
        Thickness.heavy.height(self.metrics.box_thickness),
        Thickness.heavy.height(self.metrics.box_thickness),
    );
}

fn draw_light_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.light.height(self.metrics.box_thickness),
        Thickness.heavy.height(self.metrics.box_thickness),
    );
}

fn draw_heavy_double_dash_vertical(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_dash_vertical(
        canvas,
        2,
        Thickness.heavy.height(self.metrics.box_thickness),
        Thickness.heavy.height(self.metrics.box_thickness),
    );
}

fn draw_light_diagonal_upper_right_to_lower_left(self: Box, canvas: *font.sprite.Canvas) void {
    canvas.line(.{
        .p0 = .{ .x = @floatFromInt(self.metrics.cell_width), .y = 0 },
        .p1 = .{ .x = 0, .y = @floatFromInt(self.metrics.cell_height) },
    }, @floatFromInt(Thickness.light.height(self.metrics.box_thickness)), .on) catch {};
}

fn draw_light_diagonal_upper_left_to_lower_right(self: Box, canvas: *font.sprite.Canvas) void {
    canvas.line(.{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{
            .x = @floatFromInt(self.metrics.cell_width),
            .y = @floatFromInt(self.metrics.cell_height),
        },
    }, @floatFromInt(Thickness.light.height(self.metrics.box_thickness)), .on) catch {};
}

fn draw_light_diagonal_cross(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_light_diagonal_upper_right_to_lower_left(canvas);
    self.draw_light_diagonal_upper_left_to_lower_right(canvas);
}

fn draw_block(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime alignment: Alignment,
    comptime width: f64,
    comptime height: f64,
) void {
    self.draw_block_shade(canvas, alignment, width, height, .on);
}

fn draw_block_shade(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime alignment: Alignment,
    comptime width: f64,
    comptime height: f64,
    comptime shade: Shade,
) void {
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);

    const w: u32 = @intFromFloat(@round(float_width * width));
    const h: u32 = @intFromFloat(@round(float_height * height));

    const x = switch (alignment.horizontal) {
        .left => 0,
        .right => self.metrics.cell_width - w,
        .center => (self.metrics.cell_width - w) / 2,
    };
    const y = switch (alignment.vertical) {
        .top => 0,
        .bottom => self.metrics.cell_height - h,
        .middle => (self.metrics.cell_height - h) / 2,
    };

    canvas.rect(.{
        .x = x,
        .y = y,
        .width = w,
        .height = h,
    }, @as(font.sprite.Color, @enumFromInt(@intFromEnum(shade))));
}

fn draw_corner_triangle_shade(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime corner: Corner,
    comptime shade: Shade,
) void {
    const x0, const y0, const x1, const y1, const x2, const y2 = switch (corner) {
        .tl => .{ 0, 0, 0, self.metrics.cell_height, self.metrics.cell_width, 0 },
        .tr => .{ 0, 0, self.metrics.cell_width, self.metrics.cell_height, self.metrics.cell_width, 0 },
        .bl => .{ 0, 0, 0, self.metrics.cell_height, self.metrics.cell_width, self.metrics.cell_height },
        .br => .{ 0, self.metrics.cell_height, self.metrics.cell_width, self.metrics.cell_height, self.metrics.cell_width, 0 },
    };

    canvas.triangle(.{
        .p0 = .{ .x = @floatFromInt(x0), .y = @floatFromInt(y0) },
        .p1 = .{ .x = @floatFromInt(x1), .y = @floatFromInt(y1) },
        .p2 = .{ .x = @floatFromInt(x2), .y = @floatFromInt(y2) },
    }, @as(font.sprite.Color, @enumFromInt(@intFromEnum(shade)))) catch {};
}

fn draw_full_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.rect(canvas, 0, 0, self.metrics.cell_width, self.metrics.cell_height);
}

fn draw_vertical_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const x = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.metrics.cell_width)) / 8)));
    const w = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.metrics.cell_width)) / 8)));
    self.rect(canvas, x, 0, x + w, self.metrics.cell_height);
}

fn draw_checkerboard_fill(self: Box, canvas: *font.sprite.Canvas, parity: u1) void {
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const x_size: usize = 4;
    const y_size: usize = @intFromFloat(@round(4 * (float_height / float_width)));
    for (0..x_size) |x| {
        const x0 = (self.metrics.cell_width * x) / x_size;
        const x1 = (self.metrics.cell_width * (x + 1)) / x_size;
        for (0..y_size) |y| {
            const y0 = (self.metrics.cell_height * y) / y_size;
            const y1 = (self.metrics.cell_height * (y + 1)) / y_size;
            if ((x + y) % 2 == parity) {
                canvas.rect(.{
                    .x = @intCast(x0),
                    .y = @intCast(y0),
                    .width = @intCast(x1 -| x0),
                    .height = @intCast(y1 -| y0),
                }, .on);
            }
        }
    }
}

fn draw_upper_left_to_lower_right_fill(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.metrics.box_thickness);
    const line_count = self.metrics.cell_width / (2 * thick_px);

    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const stride = @round(float_width / @as(f64, @floatFromInt(line_count)));

    for (0..line_count * 2 + 1) |_i| {
        const i = @as(i32, @intCast(_i)) - @as(i32, @intCast(line_count));
        const top_x = @as(f64, @floatFromInt(i)) * stride;
        const bottom_x = float_width + top_x;
        canvas.line(.{
            .p0 = .{ .x = top_x, .y = 0 },
            .p1 = .{ .x = bottom_x, .y = float_height },
        }, float_thick, .on) catch {};
    }
}

fn draw_upper_right_to_lower_left_fill(self: Box, canvas: *font.sprite.Canvas) void {
    const thick_px = Thickness.light.height(self.metrics.box_thickness);
    const line_count = self.metrics.cell_width / (2 * thick_px);

    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const stride = @round(float_width / @as(f64, @floatFromInt(line_count)));

    for (0..line_count * 2 + 1) |_i| {
        const i = @as(i32, @intCast(_i)) - @as(i32, @intCast(line_count));
        const bottom_x = @as(f64, @floatFromInt(i)) * stride;
        const top_x = float_width + bottom_x;
        canvas.line(.{
            .p0 = .{ .x = top_x, .y = 0 },
            .p1 = .{ .x = bottom_x, .y = float_height },
        }, float_thick, .on) catch {};
    }
}

fn draw_corner_diagonal_lines(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime corners: Quads,
) void {
    const thick_px = Thickness.light.height(self.metrics.box_thickness);

    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const center_x: f64 = @floatFromInt(self.metrics.cell_width / 2 + self.metrics.cell_width % 2);
    const center_y: f64 = @floatFromInt(self.metrics.cell_height / 2 + self.metrics.cell_height % 2);

    if (corners.tl) canvas.line(.{
        .p0 = .{ .x = center_x, .y = 0 },
        .p1 = .{ .x = 0, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.tr) canvas.line(.{
        .p0 = .{ .x = center_x, .y = 0 },
        .p1 = .{ .x = float_width, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.bl) canvas.line(.{
        .p0 = .{ .x = center_x, .y = float_height },
        .p1 = .{ .x = 0, .y = center_y },
    }, float_thick, .on) catch {};

    if (corners.br) canvas.line(.{
        .p0 = .{ .x = center_x, .y = float_height },
        .p1 = .{ .x = float_width, .y = center_y },
    }, float_thick, .on) catch {};
}

fn draw_cell_diagonal(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime from: Alignment,
    comptime to: Alignment,
) void {
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);

    const x0: f64 = switch (from.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y0: f64 = switch (from.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };
    const x1: f64 = switch (to.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y1: f64 = switch (to.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };

    self.draw_line(
        canvas,
        .{ .x = x0, .y = y0 },
        .{ .x = x1, .y = y1 },
        .light,
    ) catch {};
}

fn draw_fading_line(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime to: Edge,
    comptime thickness: Thickness,
) void {
    const thick_px = thickness.height(self.metrics.box_thickness);
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);

    // Top of horizontal strokes
    const h_top = (self.metrics.cell_height -| thick_px) / 2;
    // Bottom of horizontal strokes
    const h_bottom = h_top +| thick_px;
    // Left of vertical strokes
    const v_left = (self.metrics.cell_width -| thick_px) / 2;
    // Right of vertical strokes
    const v_right = v_left +| thick_px;

    // If we're fading to the top or left, we start with 0.0
    // and increment up as we progress, otherwise we start
    // at 255.0 and increment down (negative).
    var color: f64 = switch (to) {
        .top, .left => 0.0,
        .bottom, .right => 255.0,
    };
    const inc: f64 = 255.0 / switch (to) {
        .top => float_height,
        .bottom => -float_height,
        .left => float_width,
        .right => -float_width,
    };

    switch (to) {
        .top, .bottom => {
            for (0..self.metrics.cell_height) |y| {
                for (v_left..v_right) |x| {
                    canvas.pixel(
                        @intCast(x),
                        @intCast(y),
                        @enumFromInt(@as(u8, @intFromFloat(@round(color)))),
                    );
                }
                color += inc;
            }
        },
        .left, .right => {
            for (0..self.metrics.cell_width) |x| {
                for (h_top..h_bottom) |y| {
                    canvas.pixel(
                        @intCast(x),
                        @intCast(y),
                        @enumFromInt(@as(u8, @intFromFloat(@round(color)))),
                    );
                }
                color += inc;
            }
        },
    }
}

fn draw_branch_node(
    self: Box,
    canvas: *font.sprite.Canvas,
    node: BranchNode,
    comptime thickness: Thickness,
) void {
    const thick_px = thickness.height(self.metrics.box_thickness);
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);

    // Top of horizontal strokes
    const h_top = (self.metrics.cell_height -| thick_px) / 2;
    // Bottom of horizontal strokes
    const h_bottom = h_top +| thick_px;
    // Left of vertical strokes
    const v_left = (self.metrics.cell_width -| thick_px) / 2;
    // Right of vertical strokes
    const v_right = v_left +| thick_px;

    // We calculate the center of the circle this way
    // to ensure it aligns with box drawing characters
    // since the lines are sometimes off center to
    // make sure they aren't split between pixels.
    const cx: f64 = @as(f64, @floatFromInt(v_left)) + float_thick / 2;
    const cy: f64 = @as(f64, @floatFromInt(h_top)) + float_thick / 2;
    // The radius needs to be the smallest distance from the center to an edge.
    const r: f64 = @min(
        @min(cx, cy),
        @min(float_width - cx, float_height - cy),
    );

    var ctx = canvas.getContext() catch return;
    defer ctx.deinit();
    ctx.setSource(.{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } });
    ctx.setLineWidth(float_thick);

    // These @intFromFloat casts shouldn't ever fail since r can never
    // be greater than cx or cy, so when subtracting it from them the
    // result can never be negative.
    if (node.up)
        self.rect(canvas, v_left, 0, v_right, @intFromFloat(@ceil(cy - r)));
    if (node.right)
        self.rect(canvas, @intFromFloat(@floor(cx + r)), h_top, self.metrics.cell_width, h_bottom);
    if (node.down)
        self.rect(canvas, v_left, @intFromFloat(@floor(cy + r)), v_right, self.metrics.cell_height);
    if (node.left)
        self.rect(canvas, 0, h_top, @intFromFloat(@ceil(cx - r)), h_bottom);

    if (node.filled) {
        ctx.arc(cx, cy, r, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.fill() catch return;
    } else {
        ctx.arc(cx, cy, r - float_thick / 2, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.stroke() catch return;
    }
}

fn draw_circle(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime position: Alignment,
    comptime filled: bool,
) void {
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);

    const x: f64 = switch (position.horizontal) {
        .left => 0,
        .right => float_width,
        .center => float_width / 2,
    };
    const y: f64 = switch (position.vertical) {
        .top => 0,
        .bottom => float_height,
        .middle => float_height / 2,
    };
    const r: f64 = 0.5 * @min(float_width, float_height);

    var ctx = canvas.getContext() catch return;
    defer ctx.deinit();
    ctx.setSource(.{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } });
    ctx.setLineWidth(
        @floatFromInt(Thickness.light.height(self.metrics.box_thickness)),
    );

    if (filled) {
        ctx.arc(x, y, r, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.fill() catch return;
    } else {
        ctx.arc(x, y, r - ctx.line_width / 2, 0, std.math.pi * 2) catch return;
        ctx.closePath() catch return;
        ctx.stroke() catch return;
    }
}

fn draw_line(
    self: Box,
    canvas: *font.sprite.Canvas,
    p0: font.sprite.Point(f64),
    p1: font.sprite.Point(f64),
    comptime thickness: Thickness,
) !void {
    canvas.line(
        .{ .p0 = p0, .p1 = p1 },
        @floatFromInt(thickness.height(self.metrics.box_thickness)),
        .on,
    ) catch {};
}

fn draw_shade(self: Box, canvas: *font.sprite.Canvas, v: u16) void {
    canvas.rect((font.sprite.Box(u32){
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{
            .x = self.metrics.cell_width,
            .y = self.metrics.cell_height,
        },
    }).rect(), @as(font.sprite.Color, @enumFromInt(v)));
}

fn draw_light_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_shade(canvas, 0x40);
}

fn draw_medium_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_shade(canvas, 0x80);
}

fn draw_dark_shade(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_shade(canvas, 0xc0);
}

fn draw_horizontal_one_eighth_block_n(self: Box, canvas: *font.sprite.Canvas, n: u32) void {
    const h = @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.metrics.cell_height)) / 8)));
    const y = @min(
        self.metrics.cell_height -| h,
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(n)) * @as(f64, @floatFromInt(self.metrics.cell_height)) / 8))),
    );
    self.rect(canvas, 0, y, self.metrics.cell_width, y + h);
}

fn draw_horizontal_one_eighth_1358_block(self: Box, canvas: *font.sprite.Canvas) void {
    self.draw_horizontal_one_eighth_block_n(canvas, 0);
    self.draw_horizontal_one_eighth_block_n(canvas, 2);
    self.draw_horizontal_one_eighth_block_n(canvas, 4);
    self.draw_horizontal_one_eighth_block_n(canvas, 7);
}

fn draw_quadrant(self: Box, canvas: *font.sprite.Canvas, comptime quads: Quads) void {
    const center_x = self.metrics.cell_width / 2 + self.metrics.cell_width % 2;
    const center_y = self.metrics.cell_height / 2 + self.metrics.cell_height % 2;

    if (quads.tl) self.rect(canvas, 0, 0, center_x, center_y);
    if (quads.tr) self.rect(canvas, center_x, 0, self.metrics.cell_width, center_y);
    if (quads.bl) self.rect(canvas, 0, center_y, center_x, self.metrics.cell_height);
    if (quads.br) self.rect(canvas, center_x, center_y, self.metrics.cell_width, self.metrics.cell_height);
}

fn draw_braille(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    var w: u32 = @min(self.metrics.cell_width / 4, self.metrics.cell_height / 8);
    var x_spacing: u32 = self.metrics.cell_width / 4;
    var y_spacing: u32 = self.metrics.cell_height / 8;
    var x_margin: u32 = x_spacing / 2;
    var y_margin: u32 = y_spacing / 2;

    var x_px_left: u32 = self.metrics.cell_width - 2 * x_margin - x_spacing - 2 * w;
    var y_px_left: u32 = self.metrics.cell_height - 2 * y_margin - 3 * y_spacing - 4 * w;

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
    assert(2 * x_margin + 2 * w + x_spacing <= self.metrics.cell_width);
    assert(2 * y_margin + 4 * w + 3 * y_spacing <= self.metrics.cell_height);

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
    const Sextants = packed struct(u6) {
        tl: bool,
        tr: bool,
        ml: bool,
        mr: bool,
        bl: bool,
        br: bool,
    };

    assert(cp >= 0x1fb00 and cp <= 0x1fb3b);
    const idx = cp - 0x1fb00;
    const sex: Sextants = @bitCast(@as(u6, @intCast(
        idx + (idx / 0x14) + 1,
    )));

    const x_halfs = self.xHalfs();
    const y_thirds = self.yThirds();

    if (sex.tl) self.rect(canvas, 0, 0, x_halfs[0], y_thirds[0]);
    if (sex.tr) self.rect(canvas, x_halfs[1], 0, self.metrics.cell_width, y_thirds[0]);
    if (sex.ml) self.rect(canvas, 0, y_thirds[0], x_halfs[0], y_thirds[1]);
    if (sex.mr) self.rect(canvas, x_halfs[1], y_thirds[0], self.metrics.cell_width, y_thirds[1]);
    if (sex.bl) self.rect(canvas, 0, y_thirds[1], x_halfs[0], self.metrics.cell_height);
    if (sex.br) self.rect(canvas, x_halfs[1], y_thirds[1], self.metrics.cell_width, self.metrics.cell_height);
}

fn draw_octant(self: Box, canvas: *font.sprite.Canvas, cp: u32) void {
    assert(cp >= octant_min and cp <= octant_max);

    // Octant representation. We use the funny numeric string keys
    // so its easier to parse the actual name used in the Symbols for
    // Legacy Computing spec.
    const Octant = packed struct(u8) {
        @"1": bool = false,
        @"2": bool = false,
        @"3": bool = false,
        @"4": bool = false,
        @"5": bool = false,
        @"6": bool = false,
        @"7": bool = false,
        @"8": bool = false,
    };

    // Parse the octant data. This is all done at comptime so this is
    // static data that is embedded in the binary.
    const octants_len = octant_max - octant_min + 1;
    const octants: [octants_len]Octant = comptime octants: {
        @setEvalBranchQuota(10_000);

        var result: [octants_len]Octant = .{.{}} ** octants_len;
        var i: usize = 0;

        const data = @embedFile("octants.txt");
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            // Skip comments
            if (line.len == 0 or line[0] == '#') continue;

            const current = &result[i];
            i += 1;

            // Octants are in the format "BLOCK OCTANT-1235". The numbers
            // at the end are keys into our packed struct. Since we're
            // at comptime we can metaprogram it all.
            const idx = std.mem.indexOfScalar(u8, line, '-').?;
            for (line[idx + 1 ..]) |c| @field(current, &.{c}) = true;
        }

        assert(i == octants_len);
        break :octants result;
    };

    const x_halfs = self.xHalfs();
    const y_quads = self.yQuads();
    const oct = octants[cp - octant_min];
    if (oct.@"1") self.rect(canvas, 0, 0, x_halfs[0], y_quads[0]);
    if (oct.@"2") self.rect(canvas, x_halfs[1], 0, self.metrics.cell_width, y_quads[0]);
    if (oct.@"3") self.rect(canvas, 0, y_quads[0], x_halfs[0], y_quads[1]);
    if (oct.@"4") self.rect(canvas, x_halfs[1], y_quads[0], self.metrics.cell_width, y_quads[1]);
    if (oct.@"5") self.rect(canvas, 0, y_quads[1], x_halfs[0], y_quads[2]);
    if (oct.@"6") self.rect(canvas, x_halfs[1], y_quads[1], self.metrics.cell_width, y_quads[2]);
    if (oct.@"7") self.rect(canvas, 0, y_quads[2], x_halfs[0], self.metrics.cell_height);
    if (oct.@"8") self.rect(canvas, x_halfs[1], y_quads[2], self.metrics.cell_width, self.metrics.cell_height);
}

fn xHalfs(self: Box) [2]u32 {
    return .{
        @as(u32, @intFromFloat(@round(@as(f64, @floatFromInt(self.metrics.cell_width)) / 2))),
        @as(u32, @intFromFloat(@as(f64, @floatFromInt(self.metrics.cell_width)) / 2)),
    };
}

fn yThirds(self: Box) [2]u32 {
    return switch (@mod(self.metrics.cell_height, 3)) {
        0 => .{ self.metrics.cell_height / 3, 2 * self.metrics.cell_height / 3 },
        1 => .{ self.metrics.cell_height / 3, 2 * self.metrics.cell_height / 3 + 1 },
        2 => .{ self.metrics.cell_height / 3 + 1, 2 * self.metrics.cell_height / 3 },
        else => unreachable,
    };
}

// assume octants might be striped across multiple rows of cells. to maximize
// distance between excess pixellines, we want (1) an arbitrary region (there
// will be a pattern of 1'-3-1'-3-1'-3 no matter what), (2) discontiguous
// regions (0 and 2 or 1 and 3), and (3) an arbitrary three regions (there will
// be a pattern of 3-1-3-1-3-1 no matter what).
fn yQuads(self: Box) [3]u32 {
    return switch (@mod(self.metrics.cell_height, 4)) {
        0 => .{ self.metrics.cell_height / 4, 2 * self.metrics.cell_height / 4, 3 * self.metrics.cell_height / 4 },
        1 => .{ self.metrics.cell_height / 4, 2 * self.metrics.cell_height / 4 + 1, 3 * self.metrics.cell_height / 4 },
        2 => .{ self.metrics.cell_height / 4 + 1, 2 * self.metrics.cell_height / 4, 3 * self.metrics.cell_height / 4 + 1 },
        3 => .{ self.metrics.cell_height / 4 + 1, 2 * self.metrics.cell_height / 4 + 1, 3 * self.metrics.cell_height / 4 },
        else => unreachable,
    };
}

fn draw_smooth_mosaic(
    self: Box,
    canvas: *font.sprite.Canvas,
    mosaic: SmoothMosaic,
) !void {
    const y_thirds = self.yThirds();
    const top: f64 = 0.0;
    const upper: f64 = @floatFromInt(y_thirds[0]);
    const lower: f64 = @floatFromInt(y_thirds[1]);
    const bottom: f64 = @floatFromInt(self.metrics.cell_height);
    const left: f64 = 0.0;
    const center: f64 = @round(@as(f64, @floatFromInt(self.metrics.cell_width)) / 2);
    const right: f64 = @floatFromInt(self.metrics.cell_width);

    var path: z2d.StaticPath(12) = .{};
    path.init(); // nodes.len = 0

    if (mosaic.tl) path.lineTo(left, top); // +1, nodes.len = 1
    if (mosaic.ul) path.lineTo(left, upper); // +1, nodes.len = 2
    if (mosaic.ll) path.lineTo(left, lower); // +1, nodes.len = 3
    if (mosaic.bl) path.lineTo(left, bottom); // +1, nodes.len = 4
    if (mosaic.bc) path.lineTo(center, bottom); // +1, nodes.len = 5
    if (mosaic.br) path.lineTo(right, bottom); // +1, nodes.len = 6
    if (mosaic.lr) path.lineTo(right, lower); // +1, nodes.len = 7
    if (mosaic.ur) path.lineTo(right, upper); // +1, nodes.len = 8
    if (mosaic.tr) path.lineTo(right, top); // +1, nodes.len = 9
    if (mosaic.tc) path.lineTo(center, top); // +1, nodes.len = 10
    path.close(); // +2, nodes.len = 12

    try z2d.painter.fill(
        canvas.alloc,
        &canvas.sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } },
        } },
        path.wrapped_path.nodes.items,
        .{},
    );
}

fn draw_edge_triangle(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime edge: Edge,
) !void {
    const upper: f64 = 0.0;
    const middle: f64 = @round(@as(f64, @floatFromInt(self.metrics.cell_height)) / 2);
    const lower: f64 = @floatFromInt(self.metrics.cell_height);
    const left: f64 = 0.0;
    const center: f64 = @round(@as(f64, @floatFromInt(self.metrics.cell_width)) / 2);
    const right: f64 = @floatFromInt(self.metrics.cell_width);

    const x0, const y0, const x1, const y1 = switch (edge) {
        .top => .{ right, upper, left, upper },
        .left => .{ left, upper, left, lower },
        .bottom => .{ left, lower, right, lower },
        .right => .{ right, lower, right, upper },
    };

    var path: z2d.StaticPath(5) = .{};
    path.init(); // nodes.len = 0

    path.moveTo(center, middle); // +1, nodes.len = 1
    path.lineTo(x0, y0); // +1, nodes.len = 2
    path.lineTo(x1, y1); // +1, nodes.len = 3
    path.close(); // +2, nodes.len = 5

    try z2d.painter.fill(
        canvas.alloc,
        &canvas.sfc,
        &.{ .opaque_pattern = .{
            .pixel = .{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } },
        } },
        path.wrapped_path.nodes.items,
        .{},
    );
}

fn draw_arc(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime corner: Corner,
    comptime thickness: Thickness,
) !void {
    const thick_px = thickness.height(self.metrics.box_thickness);
    const float_width: f64 = @floatFromInt(self.metrics.cell_width);
    const float_height: f64 = @floatFromInt(self.metrics.cell_height);
    const float_thick: f64 = @floatFromInt(thick_px);
    const center_x: f64 = @as(f64, @floatFromInt((self.metrics.cell_width -| thick_px) / 2)) + float_thick / 2;
    const center_y: f64 = @as(f64, @floatFromInt((self.metrics.cell_height -| thick_px) / 2)) + float_thick / 2;

    const r = @min(float_width, float_height) / 2;

    // Fraction away from the center to place the middle control points,
    const s: f64 = 0.25;

    var ctx = try canvas.getContext();
    defer ctx.deinit();
    ctx.setSource(.{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } });
    ctx.setLineWidth(float_thick);
    ctx.setLineCapMode(.round);

    switch (corner) {
        .tl => {
            try ctx.moveTo(center_x, 0);
            try ctx.lineTo(center_x, center_y - r);
            try ctx.curveTo(
                center_x,
                center_y - s * r,
                center_x - s * r,
                center_y,
                center_x - r,
                center_y,
            );
            try ctx.lineTo(0, center_y);
        },
        .tr => {
            try ctx.moveTo(center_x, 0);
            try ctx.lineTo(center_x, center_y - r);
            try ctx.curveTo(
                center_x,
                center_y - s * r,
                center_x + s * r,
                center_y,
                center_x + r,
                center_y,
            );
            try ctx.lineTo(float_width, center_y);
        },
        .bl => {
            try ctx.moveTo(center_x, float_height);
            try ctx.lineTo(center_x, center_y + r);
            try ctx.curveTo(
                center_x,
                center_y + s * r,
                center_x - s * r,
                center_y,
                center_x - r,
                center_y,
            );
            try ctx.lineTo(0, center_y);
        },
        .br => {
            try ctx.moveTo(center_x, float_height);
            try ctx.lineTo(center_x, center_y + r);
            try ctx.curveTo(
                center_x,
                center_y + s * r,
                center_x + s * r,
                center_y,
                center_x + r,
                center_y,
            );
            try ctx.lineTo(float_width, center_y);
        },
    }
    try ctx.stroke();
}

fn draw_dash_horizontal(
    self: Box,
    canvas: *font.sprite.Canvas,
    count: u8,
    thick_px: u32,
    desired_gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // +------------+
    // |            |
    // |            |
    // |            |
    // |            |
    // | --  --  -- |
    // |            |
    // |            |
    // |            |
    // |            |
    // +------------+
    // Our dashed line should be made such that when tiled horizontally
    // it creates one consistent line with no uneven gap or segment sizes.
    // In order to make sure this is the case, we should have half-sized
    // gaps on the left and right so that it is centered properly.

    // For N dashes, there are N - 1 gaps between them, but we also have
    // half-sized gaps on either side, adding up to N total gaps.
    const gap_count = count;

    // We need at least 1 pixel for each gap and each dash, if we don't
    // have that then we can't draw our dashed line correctly so we just
    // draw a solid line and return.
    if (self.metrics.cell_width < count + gap_count) {
        self.hline_middle(canvas, .light);
        return;
    }

    // We never want the gaps to take up more than 50% of the space,
    // because if they do the dashes are too small and look wrong.
    const gap_width = @min(desired_gap, self.metrics.cell_width / (2 * count));
    const total_gap_width = gap_count * gap_width;
    const total_dash_width = self.metrics.cell_width - total_gap_width;
    const dash_width = total_dash_width / count;
    const remaining = total_dash_width % count;

    assert(dash_width * count + gap_width * gap_count + remaining == self.metrics.cell_width);

    // Our dashes should be centered vertically.
    const y: u32 = (self.metrics.cell_height -| thick_px) / 2;

    // We start at half a gap from the left edge, in order to center
    // our dashes properly.
    var x: u32 = gap_width / 2;

    // We'll distribute the extra space in to dash widths, 1px at a
    // time. We prefer this to making gaps larger since that is much
    // more visually obvious.
    var extra: u32 = remaining;

    for (0..count) |_| {
        var x1 = x + dash_width;
        // We distribute left-over size in to dash widths,
        // since it's less obvious there than in the gaps.
        if (extra > 0) {
            extra -= 1;
            x1 += 1;
        }
        self.hline(canvas, x, x1, y, thick_px);
        // Advance by the width of the dash we drew and the width
        // of a gap to get the the start of the next dash.
        x = x1 + gap_width;
    }
}

fn draw_dash_vertical(
    self: Box,
    canvas: *font.sprite.Canvas,
    comptime count: u8,
    thick_px: u32,
    desired_gap: u32,
) void {
    assert(count >= 2 and count <= 4);

    // +-----------+
    // |     |     |
    // |     |     |
    // |           |
    // |     |     |
    // |     |     |
    // |           |
    // |     |     |
    // |     |     |
    // |           |
    // +-----------+
    // Our dashed line should be made such that when tiled vertically it
    // it creates one consistent line with no uneven gap or segment sizes.
    // In order to make sure this is the case, we should have an extra gap
    // gap at the bottom.
    //
    // A single full-sized extra gap is preferred to two half-sized ones for
    // vertical to allow better joining to solid characters without creating
    // visible half-sized gaps. Unlike horizontal, centering is a lot less
    // important, visually.

    // Because of the extra gap at the bottom, there are as many gaps as
    // there are dashes.
    const gap_count = count;

    // We need at least 1 pixel for each gap and each dash, if we don't
    // have that then we can't draw our dashed line correctly so we just
    // draw a solid line and return.
    if (self.metrics.cell_height < count + gap_count) {
        self.vline_middle(canvas, .light);
        return;
    }

    // We never want the gaps to take up more than 50% of the space,
    // because if they do the dashes are too small and look wrong.
    const gap_height = @min(desired_gap, self.metrics.cell_height / (2 * count));
    const total_gap_height = gap_count * gap_height;
    const total_dash_height = self.metrics.cell_height - total_gap_height;
    const dash_height = total_dash_height / count;
    const remaining = total_dash_height % count;

    assert(dash_height * count + gap_height * gap_count + remaining == self.metrics.cell_height);

    // Our dashes should be centered horizontally.
    const x: u32 = (self.metrics.cell_width -| thick_px) / 2;

    // We start at the top of the cell.
    var y: u32 = 0;

    // We'll distribute the extra space in to dash heights, 1px at a
    // time. We prefer this to making gaps larger since that is much
    // more visually obvious.
    var extra: u32 = remaining;

    inline for (0..count) |_| {
        var y1 = y + dash_height;
        // We distribute left-over size in to dash widths,
        // since it's less obvious there than in the gaps.
        if (extra > 0) {
            extra -= 1;
            y1 += 1;
        }
        self.vline(canvas, y, y1, x, thick_px);
        // Advance by the height of the dash we drew and the height
        // of a gap to get the the start of the next dash.
        y = y1 + gap_height;
    }
}

fn vline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.metrics.box_thickness);
    self.vline(canvas, 0, self.metrics.cell_height, (self.metrics.cell_width -| thick_px) / 2, thick_px);
}

fn hline_middle(self: Box, canvas: *font.sprite.Canvas, thickness: Thickness) void {
    const thick_px = thickness.height(self.metrics.box_thickness);
    self.hline(canvas, 0, self.metrics.cell_width, (self.metrics.cell_height -| thick_px) / 2, thick_px);
}

fn vline(
    self: Box,
    canvas: *font.sprite.Canvas,
    y1: u32,
    y2: u32,
    x: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box(u32){ .p0 = .{
        .x = @min(@max(x, 0), self.metrics.cell_width),
        .y = @min(@max(y1, 0), self.metrics.cell_height),
    }, .p1 = .{
        .x = @min(@max(x + thickness_px, 0), self.metrics.cell_width),
        .y = @min(@max(y2, 0), self.metrics.cell_height),
    } }).rect(), .on);
}

fn hline(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    x2: u32,
    y: u32,
    thickness_px: u32,
) void {
    canvas.rect((font.sprite.Box(u32){ .p0 = .{
        .x = @min(@max(x1, 0), self.metrics.cell_width),
        .y = @min(@max(y, 0), self.metrics.cell_height),
    }, .p1 = .{
        .x = @min(@max(x2, 0), self.metrics.cell_width),
        .y = @min(@max(y + thickness_px, 0), self.metrics.cell_height),
    } }).rect(), .on);
}

fn rect(
    self: Box,
    canvas: *font.sprite.Canvas,
    x1: u32,
    y1: u32,
    x2: u32,
    y2: u32,
) void {
    canvas.rect((font.sprite.Box(u32){ .p0 = .{
        .x = @min(@max(x1, 0), self.metrics.cell_width),
        .y = @min(@max(y1, 0), self.metrics.cell_height),
    }, .p1 = .{
        .x = @min(@max(x2, 0), self.metrics.cell_width),
        .y = @min(@max(y2, 0), self.metrics.cell_height),
    } }).rect(), .on);
}

// Separated Block Quadrants from Symbols for Legacy Computing Supplement
// 𜰡 𜰢 𜰣 𜰤 𜰥 𜰦 𜰧 𜰨 𜰩 𜰪 𜰫 𜰬 𜰭 𜰮 𜰯
fn draw_separated_block_quadrant(self: Box, canvas: *font.sprite.Canvas, comptime fmt: []const u8) !void {
    comptime {
        if (fmt.len > 4) @compileError("cannot have more than four quadrants");
        var seen = [_]bool{false} ** (std.math.maxInt(u8) + 1);
        for (fmt) |c| {
            if (seen[c]) @compileError("repeated quadrants not allowed");
            seen[c] = true;
            switch (c) {
                '1'...'4' => {},
                else => @compileError("invalid quadrant"),
            }
        }
    }

    var ctx = try canvas.getContext();
    defer ctx.deinit();
    ctx.setSource(.{ .alpha8 = .{ .a = @intFromEnum(Shade.on) } });

    const gap: f64 = @max(1.0, @as(f64, @floatFromInt(self.metrics.cell_width)) * 0.10) / 2.0;
    const left: f64 = gap;
    const right = @as(f64, @floatFromInt(self.metrics.cell_width)) - gap;
    const top: f64 = gap;
    const bottom = @as(f64, @floatFromInt(self.metrics.cell_height)) - gap;
    const center_x = @as(f64, @floatFromInt(self.metrics.cell_width)) / 2.0;
    const center_left = center_x - gap;
    const center_right = center_x + gap;
    const center_y = @as(f64, @floatFromInt(self.metrics.cell_height)) / 2.0;
    const center_top = center_y - gap;
    const center_bottom = center_y + gap;

    inline for (fmt) |c| {
        const x1, const y1, const x2, const y2 = switch (c) {
            '1' => .{
                left,        top,
                center_left, center_top,
            },
            '2' => .{
                center_right, top,
                right,        center_top,
            },
            '3' => .{
                left,        center_bottom,
                center_left, bottom,
            },
            '4' => .{
                center_right, center_bottom,
                right,        bottom,
            },
            else => unreachable,
        };
        try ctx.moveTo(x1, y1);
        try ctx.lineTo(x2, y1);
        try ctx.lineTo(x2, y2);
        try ctx.lineTo(x1, y2);
        try ctx.closePath();
    }

    try ctx.fill();
}

test "all" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var cp: u32 = 0x2500;
    const end = 0x259f;
    while (cp <= end) : (cp += 1) {
        var atlas_grayscale = try font.Atlas.init(alloc, 512, .grayscale);
        defer atlas_grayscale.deinit(alloc);

        const face: Box = .{
            .metrics = font.Metrics.calc(.{
                .cell_width = 18.0,
                .ascent = 30.0,
                .descent = -6.0,
                .line_gap = 0.0,
            }),
        };
        const glyph = try face.renderGlyph(
            alloc,
            &atlas_grayscale,
            cp,
        );
        try testing.expectEqual(@as(u32, face.metrics.cell_width), glyph.width);
        try testing.expectEqual(@as(u32, face.metrics.cell_height), glyph.height);
    }
}

fn testRenderAll(self: Box, alloc: Allocator, atlas: *font.Atlas) !void {
    // Box Drawing and Block Elements.
    var cp: u32 = 0x2500;
    while (cp <= 0x259f) : (cp += 1) {
        _ = try self.renderGlyph(
            alloc,
            atlas,
            cp,
        );
    }

    // Braille
    cp = 0x2800;
    while (cp <= 0x28ff) : (cp += 1) {
        _ = try self.renderGlyph(
            alloc,
            atlas,
            cp,
        );
    }

    // Symbols for Legacy Computing.
    cp = 0x1fb00;
    while (cp <= 0x1fbef) : (cp += 1) {
        switch (cp) {
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
            => _ = try self.renderGlyph(
                alloc,
                atlas,
                cp,
            ),
            else => {},
        }
    }

    // Branch drawing character set, used for drawing git-like
    // graphs in the terminal. Originally implemented in Kitty.
    // Ref:
    // - https://github.com/kovidgoyal/kitty/pull/7681
    // - https://github.com/kovidgoyal/kitty/pull/7805
    // NOTE: Kitty is GPL licensed, and its code was not referenced
    //       for these characters, only the loose specification of
    //       the character set in the pull request descriptions.
    //
    // TODO(qwerasd): This should be in another file, but really the
    //                general organization of the sprite font code
    //                needs to be reworked eventually.
    //
    //          
    //                    
    //                    
    //            
    cp = 0xf5d0;
    while (cp <= 0xf60d) : (cp += 1) {
        _ = try self.renderGlyph(
            alloc,
            atlas,
            cp,
        );
    }

    // Symbols for Legacy Computing Supplement: Quadrants
    // 𜰡 𜰢 𜰣 𜰤 𜰥 𜰦 𜰧 𜰨 𜰩 𜰪 𜰫 𜰬 𜰭 𜰮 𜰯
    cp = 0x1cc21;
    while (cp <= 0x1cc2f) : (cp += 1) {
        switch (cp) {
            0x1cc21...0x1cc2f => _ = try self.renderGlyph(
                alloc,
                atlas,
                cp,
            ),
            else => {},
        }
    }

    // Symbols for Legacy Computing Supplement: Octants
    cp = 0x1CD00;
    while (cp <= 0x1CDE5) : (cp += 1) {
        switch (cp) {
            0x1CD00...0x1CDE5 => _ = try self.renderGlyph(
                alloc,
                atlas,
                cp,
            ),
            else => {},
        }
    }
}

test "render all sprites" {
    // Renders all sprites to an atlas and compares
    // it to a ground truth for regression testing.

    const testing = std.testing;
    const alloc = testing.allocator;

    var atlas_grayscale = try font.Atlas.init(alloc, 1024, .grayscale);
    defer atlas_grayscale.deinit(alloc);

    // Even cell size and thickness (18 x 36)
    try (Box{
        .metrics = font.Metrics.calc(.{
            .cell_width = 18.0,
            .ascent = 30.0,
            .descent = -6.0,
            .line_gap = 0.0,
            .underline_thickness = 2.0,
            .strikethrough_thickness = 2.0,
        }),
    }).testRenderAll(alloc, &atlas_grayscale);

    // Odd cell size and thickness (9 x 15)
    try (Box{
        .metrics = font.Metrics.calc(.{
            .cell_width = 9.0,
            .ascent = 12.0,
            .descent = -3.0,
            .line_gap = 0.0,
            .underline_thickness = 1.0,
            .strikethrough_thickness = 1.0,
        }),
    }).testRenderAll(alloc, &atlas_grayscale);

    const ground_truth = @embedFile("./testdata/Box.ppm");

    var stream = std.io.changeDetectionStream(ground_truth, std.io.null_writer);
    try atlas_grayscale.dump(stream.writer());

    if (stream.changeDetected()) {
        log.err(
            \\
            \\!! [Box.zig] Change detected from ground truth!
            \\!! Dumping ./Box_test.ppm and ./Box_test_diff.ppm
            \\!! Please check changes and update Box.ppm in testdata if intended.
        ,
            .{},
        );

        const ppm = try std.fs.cwd().createFile("Box_test.ppm", .{});
        defer ppm.close();
        try atlas_grayscale.dump(ppm.writer());

        const diff = try std.fs.cwd().createFile("Box_test_diff.ppm", .{});
        defer diff.close();
        var writer = diff.writer();
        try writer.print(
            \\P6
            \\{d} {d}
            \\255
            \\
        , .{ atlas_grayscale.size, atlas_grayscale.size });
        for (ground_truth[try diff.getPos()..], atlas_grayscale.data) |a, b| {
            if (a == b) {
                try writer.writeByteNTimes(a / 3, 3);
            } else {
                try writer.writeByte(a);
                try writer.writeByte(b);
                try writer.writeByte(0);
            }
        }
    }
}
