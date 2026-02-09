#include "common.hlsl"

// Per-instance vertex attributes.
struct VSInput {
    uint2 glyph_pos    : GLYPH_POS;
    uint2 glyph_size   : GLYPH_SIZE;
    int2  bearings     : BEARINGS;
    uint2 grid_pos     : GRID_POS;
    uint4 color        : COLOR;
    uint  atlas        : ATLAS;
    uint  glyph_bools  : GLYPH_BOOLS;
    uint  vid          : SV_VertexID;
};

// Values `atlas` can take.
static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

// Masks for the `glyph_bools` attribute
static const uint NO_MIN_CONTRAST = 1u;
static const uint IS_CURSOR_GLYPH = 2u;

struct VSOutput {
    float4 position            : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR;
    nointerpolation float4 bg_color : BG_COLOR;
    float2 tex_coord           : TEXCOORD0;
};

// Background cell colors.
StructuredBuffer<uint> bg_colors : register(t0);

VSOutput vs_main(VSInput input) {
    VSOutput output;

    uint2 grid_size = unpack2u16(grid_size_packed_2u16);
    uint2 cursor_pos = unpack2u16(cursor_pos_packed_2u16);
    bool cursor_wide = (bools & CURSOR_WIDE) != 0;
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Convert grid position to world space.
    float2 cell_pos = cell_size * float2(input.grid_pos);

    int vid = input.vid;

    // Triangle strip corners:
    // 0=top-left, 1=top-right, 2=bot-left, 3=bot-right
    float2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    output.atlas = input.atlas;

    float2 size = float2(input.glyph_size);
    float2 offset = float2(input.bearings);
    offset.y = cell_size.y - offset.y;

    cell_pos = cell_pos + size * corner + offset;
    output.position = mul(projection_matrix, float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f));

    // Texture coordinate in pixels (not normalized).
    output.tex_coord = float2(input.glyph_pos) + float2(input.glyph_size) * corner;

    // Colors - always linearized for contrast calculations.
    output.color = load_color(input.color, true);

    // BG color
    output.bg_color = load_color(
        unpack4u8(bg_colors[input.grid_pos.y * grid_size.x + input.grid_pos.x]),
        true
    );

    // Blend with global bg color.
    float4 global_bg = load_color(unpack4u8(bg_color_packed_4u8), true);
    output.bg_color += global_bg * float4(1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a, 1.0 - output.bg_color.a);

    // Minimum contrast
    if (min_contrast > 1.0f && (input.glyph_bools & NO_MIN_CONTRAST) == 0) {
        output.color = contrasted_color(min_contrast, output.color, output.bg_color);
    }

    // Cursor color override
    bool is_cursor_pos = ((input.grid_pos.x == cursor_pos.x) || (cursor_wide && (input.grid_pos.x == (cursor_pos.x + 1)))) && (input.grid_pos.y == cursor_pos.y);
    if ((input.glyph_bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
        output.color = load_color(unpack4u8(cursor_color_packed_4u8), use_linear_blending);
    }

    return output;
}
