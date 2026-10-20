#include "common.glsl"

// Position the origin to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

layout(binding = 1, std430) readonly buffer bg_cells {
    uint cells[];
};

// The cell background under a fragment: the cell's own color, a region
// scroll's shifted or ghost row, or the padding's extension of an edge.
// `rel` is the fragment relative to the grid and `visible` the grid's
// extent, both from cell_bg.
vec4 cell_bg_base(vec2 rel, vec2 visible) {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Position relative to the visible grid. Its extent comes from the
    // grid itself, not from grid_padding's bottom/right, which hold the
    // leftover measured at the last resize and can be stale. While smooth
    // scrolling the grid carries one row more than is visible. Padding
    // decisions use this unshifted position; the cell lookup below then
    // applies the shift, so a partially revealed row never leaks into
    // the padding.
    vec4 bg = vec4(0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (rel.x < 0.0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            rel.x = 0.0;
        } else {
            return bg;
        }
    } else if (rel.x >= visible.x) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            rel.x = visible.x - 0.5;
        } else {
            return bg;
        }
    }

    // Clamp y position if we should extend, otherwise discard if out of bounds.
    if (rel.y < 0.0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            rel.y = 0.0;
        } else {
            return bg;
        }
    } else if (rel.y >= visible.y) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            rel.y = visible.y - 0.5;
        } else {
            return bg;
        }
    }

    float shift_y = scroll_offset.x - scroll_offset.y * cell_size.y;
    vec2 grid_px = rel - vec2(0.0, shift_y);

    // Region scroll animation: inside an animating rectangle the content
    // is drawn shifted, so look the cell up where it is drawn from. Past
    // the region's own rows that is a ghost row sliding out, if one is
    // still there, and otherwise nothing: the surface background.
    int region = region_of(grid_px);
    if (region >= 0) {
        vec4 r = region_rect[region];
        float y = grid_px.y - region_shift[region].x;
        int row = int(floor(y / cell_size.y));
        int col = clamp(int(floor(grid_px.x / cell_size.x)), 0, int(grid_size.x) - 1);
        int cols = int(grid_size.x);
        if (y >= r.y && y < r.w) {
            row = clamp(row, 0, int(grid_size.y) - 1);
            return load_color(unpack4u8(cells[row * cols + col]), use_linear_blending);
        }
        for (uint k = 0u; k < anim_counts.y; k++) {
            ivec4 ghost = ghost_rows[k];
            if (ghost.x == region && ghost.y == row) {
                return load_color(
                        unpack4u8(cells[(int(grid_size.y) + int(k)) * cols + col]),
                        use_linear_blending
                    );
            }
        }
        return bg;
    }

    ivec2 grid_pos = ivec2(floor(grid_px / cell_size));
    grid_pos = clamp(grid_pos, ivec2(0), ivec2(grid_size) - 1);

    // Load the color for the cell.
    vec4 cell_color = load_color(
            unpack4u8(cells[grid_pos.y * grid_size.x + grid_pos.x]),
            use_linear_blending
        );

    return cell_color;
}

vec4 cell_bg() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec2 rel = gl_FragCoord.xy - grid_padding.wx;
    float extra_rows = scroll_offset.x != 0.0 ? max(scroll_offset.y + scroll_offset.w, 1.0) : 0.0;
    vec2 visible = cell_size * vec2(float(grid_size.x), float(grid_size.y) - extra_rows);
    // A shifted grid sits on the height its rows don't account for, so that
    // strip is grid, not padding.
    visible.y += scroll_offset.x != 0.0 ? scroll_offset.z : 0.0;

    vec4 bg = cell_bg_base(rel, visible);

    // Cursor trail and smooth cursor: the streak behind the cursor, then
    // the cursor filling its rect over it, both over the cell background
    // and under the text, each as far as it covers the pixel. Only inside
    // the visible grid, so neither paints the padding while riding a scroll.
    if (all(greaterThanEqual(rel, vec2(0.0))) && all(lessThan(rel, visible))) {
        vec2 p = grid_pixel(gl_FragCoord.xy);
        float trail = trail_coverage(p);
        if (trail > 0.0) {
            uvec4 fill_u = unpack4u8(cursor_fill_packed_4u8);
            vec4 streak = load_color(uvec4(fill_u.rgb, 255u), use_linear_blending);
            bg = bg * (1.0 - trail) + streak * trail;
        }
        float cov = cursor_coverage(p);
        if (cov > 0.0) {
            vec4 fill = load_color(unpack4u8(cursor_fill_packed_4u8), use_linear_blending);
            bg = bg * (1.0 - fill.a * cov) + fill * cov;
        }
    }

    return bg;
}

void main() {
    out_FragColor = cell_bg();
}
