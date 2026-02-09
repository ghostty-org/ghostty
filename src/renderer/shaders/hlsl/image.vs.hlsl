#include "common.hlsl"

// Image texture for getting dimensions.
Texture2D image_tex : register(t1);

struct VSInput {
    float2 grid_pos    : GRID_POS;
    float2 cell_offset : CELL_OFFSET;
    float4 source_rect : SOURCE_RECT;
    float2 dest_size   : DEST_SIZE;
    uint   vid         : SV_VertexID;
};

struct VSOutput {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

VSOutput vs_main(VSInput input) {
    VSOutput output;

    int vid = input.vid;

    // Triangle strip corners.
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    // Texture coordinates start at source x/y and add width/height.
    output.tex_coord = input.source_rect.xy;
    output.tex_coord += input.source_rect.zw * corner;

    // Normalize coordinates.
    uint tex_w, tex_h;
    image_tex.GetDimensions(tex_w, tex_h);
    output.tex_coord /= float2(tex_w, tex_h);

    // Position starts at grid cell top-left.
    float2 image_pos = (cell_size * input.grid_pos) + input.cell_offset;
    image_pos += input.dest_size * corner;

    output.position = mul(projection_matrix, float4(image_pos.xy, 1.0, 1.0));

    return output;
}
