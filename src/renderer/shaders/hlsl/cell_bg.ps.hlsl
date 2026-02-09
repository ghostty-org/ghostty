#include "common.hlsl"

// Background cell colors as a structured buffer.
StructuredBuffer<uint> bg_cells : register(t0);

float4 cell_bg(float4 frag_coord) {
    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    // D3D11 SV_Position already has upper-left origin.
    int2 grid_pos = int2(floor((frag_coord.xy - grid_padding.wx) / cell_size));
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 bg = float4(0.0, 0.0, 0.0, 0.0);

    // Clamp x position, extends edge bg colors in to padding on sides.
    if (grid_pos.x < 0) {
        if ((padding_extend & EXTEND_LEFT) != 0) {
            grid_pos.x = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.x > (int)grid_size.x - 1) {
        if ((padding_extend & EXTEND_RIGHT) != 0) {
            grid_pos.x = (int)grid_size.x - 1;
        } else {
            return bg;
        }
    }

    // Clamp y position.
    if (grid_pos.y < 0) {
        if ((padding_extend & EXTEND_UP) != 0) {
            grid_pos.y = 0;
        } else {
            return bg;
        }
    } else if (grid_pos.y > (int)grid_size.y - 1) {
        if ((padding_extend & EXTEND_DOWN) != 0) {
            grid_pos.y = (int)grid_size.y - 1;
        } else {
            return bg;
        }
    }

    // Load the color for the cell.
    float4 cell_color = load_color(
        unpack4u8(bg_cells[grid_pos.y * grid_size.x + grid_pos.x]),
        use_linear_blending
    );

    return cell_color;
}

float4 ps_main(float4 position : SV_Position) : SV_Target {
    return cell_bg(position);
}
