#version 300 es

// These are the possible modes that "mode" can be set to. This is
// used to multiplex multiple render modes into a single shader.
//
// NOTE: this must be kept in sync with the fragment shader
const uint MODE_BG = 1u;
const uint MODE_FG = 2u;
const uint MODE_FG_CONSTRAINED = 3u;
const uint MODE_FG_COLOR = 7u;
const uint MODE_FG_POWERLINE = 15u;

// The grid coordinates (x, y) where x < columns and y < rows
in vec2 grid_coord;

// Position of the glyph in the texture.
in vec2 glyph_pos;

// Width/height of the glyph
in vec2 glyph_size;

// Offset of the top-left corner of the glyph when rendered in a rect.
in vec2 glyph_offset;

// The color for this cell in RGBA (0 to 1.0). Background or foreground
// depends on mode.
in vec4 color_in;

// Only set for MODE_FG, this is the background color of the FG text.
// This is used to detect minimal contrast for the text.
in vec4 bg_color_in;

// The mode of this shader. The mode determines what fields are used,
// what the output will be, etc. This shader is capable of executing in
// multiple "modes" so that we can share some logic and so that we can draw
// the entire terminal grid in a single GPU pass.
in uint mode_in;

// The width in cells of this item.
in uint grid_width;

// The background or foreground color for the fragment, depending on
// whether this is a background or foreground pass.
flat out vec4 color;

// The x/y coordinate for the glyph representing the font.
out vec2 glyph_tex_coords;

// The position of the cell top-left corner in screen cords. z and w
// are width and height.
flat out vec2 screen_cell_pos;

// Pass the mode forward to the fragment shader.
flat out uint mode;

uniform sampler2D text;
uniform sampler2D text_color;
uniform vec2 cell_size;
uniform vec2 grid_size;
uniform vec4 grid_padding;
uniform bool padding_vertical_top;
uniform bool padding_vertical_bottom;
uniform mat4 projection;
uniform float min_contrast;

/********************************************************************
 * Modes
 *
 *-------------------------------------------------------------------
 * MODE_BG
 *
 * In MODE_BG, this shader renders only the background color for the
 * cell. This is a simple mode where we generate a simple rectangle
 * made up of 4 vertices and then it is filled. In this mode, the output
 * "color" is the fill color for the bg.
 *
 *-------------------------------------------------------------------
 * MODE_FG
 *
 * In MODE_FG, the shader renders the glyph onto this cell and utilizes
 * the glyph texture "text". In this mode, the output "color" is the
 * fg color to use for the glyph.
 *
 */

//-------------------------------------------------------------------
// Color Functions
//-------------------------------------------------------------------

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#relativeluminancedef
float luminance_component(float c) {
    if (c <= 0.03928) {
        return c / 12.92;
    } else {
        return pow((c + 0.055) / 1.055, 2.4);
    }
}

float relative_luminance(vec3 color) {
    vec3 color_adjusted = vec3(
        luminance_component(color.r),
        luminance_component(color.g),
        luminance_component(color.b)
    );

    vec3 weights = vec3(0.2126, 0.7152, 0.0722);
    return dot(color_adjusted, weights);
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
float contrast_ratio(vec3 color1, vec3 color2) {
    float luminance1 = relative_luminance(color1) + 0.05;
    float luminance2 = relative_luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
vec4 contrasted_color(float min_ratio, vec4 fg, vec4 bg) {
    vec3 fg_premult = fg.rgb * fg.a;
    vec3 bg_premult = bg.rgb * bg.a;
    float ratio = contrast_ratio(fg_premult, bg_premult);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(vec3(1.0, 1.0, 1.0), bg_premult);
        float black_ratio = contrast_ratio(vec3(0.0, 0.0, 0.0), bg_premult);
        if (white_ratio > black_ratio) {
            return vec4(1.0, 1.0, 1.0, fg.a);
        } else {
            return vec4(0.0, 0.0, 0.0, fg.a);
        }
    }

    return fg;
}

//-------------------------------------------------------------------
// Main
//-------------------------------------------------------------------

void main() {
    // We always forward our mode unmasked because the fragment
    // shader doesn't use any of the masks.
    mode = mode_in;

    // Top-left cell coordinates converted to world space
    // Example: (1,0) with a 30 wide cell is converted to (30,0)
    vec2 cell_pos = cell_size * grid_coord;

    // Our Z value. For now we just use grid_z directly but we pull it
    // out here so the variable name is more uniform to our cell_pos and
    // in case we want to do any other math later.
    float cell_z = 0.0;

    // Turn the cell position into a vertex point depending on the
    // gl_VertexID. Since we use instanced drawing, we have 4 vertices
    // for each corner of the cell. We can use gl_VertexID to determine
    // which one we're looking at. Using this, we can use 1 or 0 to keep
    // or discard the value for the vertex.
    //
    // 0 = top-right
    // 1 = bot-right
    // 2 = bot-left
    // 3 = top-left
    vec2 position;
    position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
    position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;

    // Scaled for wide chars
    vec2 cell_size_scaled = cell_size;
    cell_size_scaled.x = cell_size_scaled.x * float(grid_width);

    switch (mode) {
    case MODE_BG:
        // If we're at the edge of the grid, we add our padding to the background
        // to extend it. Note: grid_padding is top/right/bottom/left.
        if (grid_coord.y == 0. && padding_vertical_top) {
            cell_pos.y -= grid_padding.r;
            cell_size_scaled.y += grid_padding.r;
        } else if (grid_coord.y == grid_size.y - 1. && padding_vertical_bottom) {
            cell_size_scaled.y += grid_padding.b;
        }
        if (grid_coord.x == 0.) {
            cell_pos.x -= grid_padding.a;
            cell_size_scaled.x += grid_padding.a;
        } else if (grid_coord.x == grid_size.x - 1.) {
            cell_size_scaled.x += grid_padding.g;
        }

        // Calculate the final position of our cell in world space.
        // We have to add our cell size since our vertices are offset
        // one cell up and to the left. (Do the math to verify yourself)
        cell_pos = cell_pos + cell_size_scaled * position;

        gl_Position = projection * vec4(cell_pos, cell_z, 1.0);
        color = color_in / 255.0;
        break;

    case MODE_FG:
    case MODE_FG_CONSTRAINED:
    case MODE_FG_COLOR:
    case MODE_FG_POWERLINE:
        vec2 glyph_offset_calc = glyph_offset;

        // The glyph_offset.y is the y bearing, a y value that when added
        // to the baseline is the offset (+y is up). Our grid goes down.
        // So we flip it with `cell_size.y - glyph_offset.y`.
        glyph_offset_calc.y = -glyph_offset_calc.y;

        // If this is a constrained mode, we need to constrain it!
        // We also always constrain colored glyphs since we should have
        // their scaled cell size exactly correct.
        vec2 glyph_size_calc = glyph_size;
        if (mode == MODE_FG_CONSTRAINED || mode == MODE_FG_COLOR) {
            if (glyph_size.x > cell_size_scaled.x) {
                float new_y = glyph_size.y * (cell_size_scaled.x / glyph_size.x);
                glyph_offset_calc.y = glyph_offset_calc.y + ((glyph_size.y - new_y) / 2.);
                glyph_size_calc.y = new_y;
                glyph_size_calc.x = cell_size_scaled.x;
            }
        }

        // Calculate the final position of the cell.
        cell_pos = cell_pos + (glyph_size_calc * position) + glyph_offset_calc;
        gl_Position = projection * vec4(cell_pos, cell_z, 1.0);

        // We need to convert our texture position and size to normalized
        // device coordinates (0 to 1.0) by dividing by the size of the texture.
        ivec2 text_size;
        switch(mode) {
        case MODE_FG_CONSTRAINED:
        case MODE_FG_POWERLINE:
        case MODE_FG:
            text_size = textureSize(text, 0);
            break;

        case MODE_FG_COLOR:
            text_size = textureSize(text_color, 0);
            break;
        }
        vec2 glyph_tex_pos = glyph_pos / vec2(text_size);
        vec2 glyph_tex_size = glyph_size / vec2(text_size);
        glyph_tex_coords = glyph_tex_pos + glyph_tex_size * position;

        // If we have a minimum contrast, we need to check if we need to
        // change the color of the text to ensure it has enough contrast
        // with the background.
        // We only apply this adjustment to "normal" text with MODE_FG,
        // since we want color glyphs to appear in their original color
        // and Powerline glyphs to be unaffected (else parts of the line would
        // have different colors as some parts are displayed via background colors).
        vec4 color_final = color_in / 255.0;
        if (min_contrast > 1.0 && mode == MODE_FG) {
            vec4 bg_color = bg_color_in / 255.0;
            color_final = contrasted_color(min_contrast, color_final, bg_color);
        }
        color = color_final;
        break;
    }
}
