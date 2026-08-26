#include "common.glsl"

layout(binding = 1, std430) readonly buffer bg_cells {
    uint cells[];
};

out CellBgVertexOut {
    flat vec4 color;
} out_data;

void main() {
    uvec2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint cols = grid_size.x;
    uint rows = grid_size.y;
    uint iid = uint(gl_InstanceID);
    uint x = iid % cols;
    uint y = iid / cols;
    uvec4 cell_color = unpack4u8(cells[iid]);

    // Default-bg cells are alpha 0. Degenerate so they are not rasterized;
    // the clear, background image, or kitty-below-bg shows through.
    if (cell_color.a == 0u || y >= rows) {
        gl_Position = vec4(2.0, 2.0, 0.0, 1.0);
        out_data.color = vec4(0.0);
        return;
    }

    // Same triangle strip corners as cell_text:
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    int vid = gl_VertexID;
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    vec2 origin = cell_size * vec2(x, y);
    vec2 size = cell_size;

    // Extend edge cells into window padding when padding_extend is set.
    // grid_padding is (top, right, bottom, left).
    if (x == 0u && (padding_extend & EXTEND_LEFT) != 0u) {
        origin.x -= grid_padding.w;
        size.x += grid_padding.w;
    }
    if (x == cols - 1u && (padding_extend & EXTEND_RIGHT) != 0u) {
        size.x += grid_padding.y;
    }
    if (y == 0u && (padding_extend & EXTEND_UP) != 0u) {
        origin.y -= grid_padding.x;
        size.y += grid_padding.x;
    }
    if (y == rows - 1u && (padding_extend & EXTEND_DOWN) != 0u) {
        size.y += grid_padding.z;
    }

    vec2 pos = origin + size * corner;
    gl_Position = projection_matrix * vec4(pos.x, pos.y, 0.0, 1.0);

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    out_data.color = load_color(cell_color, use_linear_blending);
}
