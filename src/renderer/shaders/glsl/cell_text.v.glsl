#include "common.glsl"

// The position of the glyph in the texture (x, y)
layout(location = 0) in uvec2 glyph_pos;

// The size of the glyph in the texture (w, h)
layout(location = 1) in uvec2 glyph_size;

// The left and top bearings for the glyph (x, y)
layout(location = 2) in ivec2 bearings;

// The grid coordinates (x, y) where x < columns and y < rows
layout(location = 3) in uvec2 grid_pos;

// The color of the rendered text glyph.
layout(location = 4) in uvec4 color;

// The mode for this cell.
layout(location = 5) in uint mode;

// The width to constrain the glyph to, in cells, or 0 for no constraint.
layout(location = 6) in uint constraint_width;

// These are the possible modes that "mode" can be set to. This is
// used to multiplex multiple render modes into a single shader.
const uint MODE_TEXT = 1u;
const uint MODE_TEXT_CONSTRAINED = 2u;
const uint MODE_TEXT_COLOR = 3u;
const uint MODE_TEXT_CURSOR = 4u;
const uint MODE_TEXT_POWERLINE = 5u;

out CellTextVertexOut {
    flat uint mode;
    flat vec4 color;
    flat vec4 bg_color;
    vec2 tex_coord;
} out_data;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint bg_colors[];
};

void main() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uvec2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Convert the grid x, y into world space x, y by accounting for cell size
    vec2 cell_pos = cell_size * vec2(grid_pos);

    int vid = gl_VertexID;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    out_data.mode = mode;

    //              === Grid Cell ===
    //      +X
    // 0,0--...->
    //   |
    //   . offset.x = bearings.x
    // +Y.               .|.
    //   .               | |
    //   |   cell_pos -> +-------+   _.
    //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
    //                 | | .###. | |
    //                 | | #...# | |
    //   glyph_size.y -+ | ##### | |
    //                 | | #.... | +- bearings.y
    //                 |_| .#### | |
    //                   |       |_|
    //                   +-------+
    //                     |_._|
    //                       |
    //                  glyph_size.x
    //
    // In order to get the top left of the glyph, we compute an offset based on
    // the bearings. The Y bearing is the distance from the bottom of the cell
    // to the top of the glyph, so we subtract it from the cell height to get
    // the y offset. The X bearing is the distance from the left of the cell
    // to the left of the glyph, so it works as the x offset directly.

    vec2 size = vec2(glyph_size);
    vec2 offset = vec2(bearings);

    offset.y = cell_size.y - offset.y;

    // If we're constrained then we need to scale the glyph.
    if (mode == MODE_TEXT_CONSTRAINED) {
        float max_width = cell_size.x * constraint_width;
        // If this glyph is wider than the constraint width,
        // fit it to the width and remove its horizontal offset.
        if (size.x > max_width) {
            float new_y = size.y * (max_width / size.x);
            offset.y += (size.y - new_y) / 2.0;
            offset.x = 0.0;
            size.y = new_y;
            size.x = max_width;
        } else if (max_width - size.x > offset.x) {
            // However, if it does fit in the constraint width, make
            // sure the offset is small enough to not push it over the
            // right edge of the constraint width.
            offset.x = max_width - size.x;
        }
    }

    // Calculate the final position of the cell which uses our glyph size
    // and glyph offset to create the correct bounding box for the glyph.
    cell_pos = cell_pos + size * corner + offset;
    gl_Position = projection_matrix * vec4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

    // Calculate the texture coordinate in pixels. This is NOT normalized
    // (between 0.0 and 1.0), and does not need to be, since the texture will
    // be sampled with pixel coordinate mode.
    out_data.tex_coord = vec2(glyph_pos) + vec2(glyph_size) * corner;

    // Get our color. We always fetch a linearized version to
    // make it easier to handle minimum contrast calculations.
    out_data.color = load_color(color, true);
    // Get the BG color
    out_data.bg_color = load_color(
            unpack4u8(bg_colors[grid_pos.y * grid_size.x + grid_pos.x]),
            true
        );
    // Blend it with the global bg color
    vec4 global_bg = load_color(
            unpack4u8(bg_color_packed_4u8),
            true
        );
    out_data.bg_color += global_bg * vec4(1.0 - out_data.bg_color.a);

    // If we have a minimum contrast, we need to check if we need to
    // change the color of the text to ensure it has enough contrast
    // with the background.
    // We only apply this adjustment to "normal" text with MODE_TEXT,
    // since we want color glyphs to appear in their original color
    // and Powerline glyphs to be unaffected (else parts of the line would
    // have different colors as some parts are displayed via background colors).
    if (min_contrast > 1.0f && mode == MODE_TEXT) {
        // Ensure our minimum contrast
        out_data.color = contrasted_color(min_contrast, out_data.color, out_data.bg_color);
    }

    // Check if current position is under cursor (including wide cursor)
    bool is_cursor_pos = ((grid_pos.x == cursor_pos.x) || (cursor_wide && (grid_pos.x == (cursor_pos.x + 1)))) && (grid_pos.y == cursor_pos.y);

    // If this cell is the cursor cell, then we need to change the color.
    if (mode != MODE_TEXT_CURSOR && is_cursor_pos) {
        out_data.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }
}
