// Cell grid shader for the DX11 SwapChainPanel spike.
//
// Renders a terminal-like grid of cells using instanced drawing.
// Each cell instance provides bg/fg colors and a glyph index.
// The vertex shader generates a quad (2 triangles, 6 vertices) per cell
// from SV_VertexID + SV_InstanceID, positioned using a constant buffer.

cbuffer Constants : register(b0) {
    float2 grid_size;     // (cols, rows)
    float2 cell_size_px;  // cell size in pixels
    float2 viewport_size; // swap chain size in pixels
    float time;           // elapsed seconds (for animations)
    float _pad;
};

struct CellInstance {
    float4 bg_color : BG_COLOR;
    float4 fg_color : FG_COLOR;
    uint glyph_index : GLYPH_INDEX;
};

struct VS_OUTPUT {
    float4 position : SV_POSITION;
    float4 bg_color : COLOR0;
    float4 fg_color : COLOR1;
    float2 cell_uv : TEXCOORD0;
    nointerpolation uint glyph_index : GLYPH_INDEX;
};

VS_OUTPUT VSMain(uint vertex_id : SV_VertexID, uint instance_id : SV_InstanceID, CellInstance cell) {
    VS_OUTPUT output;

    uint col = instance_id % (uint)grid_size.x;
    uint row = instance_id / (uint)grid_size.x;

    // Quad vertices: two triangles forming a rectangle.
    static const float2 offsets[6] = {
        float2(0, 0), float2(1, 0), float2(0, 1),
        float2(1, 0), float2(1, 1), float2(0, 1),
    };
    float2 offset = offsets[vertex_id % 6];

    // Cell position in pixels.
    float2 pos_px = float2(col, row) * cell_size_px + offset * cell_size_px;

    // Convert to NDC: x [-1,1], y [-1,1] with Y flipped for DirectX.
    output.position = float4(
        pos_px.x / viewport_size.x * 2.0 - 1.0,
        -(pos_px.y / viewport_size.y * 2.0 - 1.0),
        0.0, 1.0
    );

    output.bg_color = cell.bg_color;
    output.fg_color = cell.fg_color;
    output.cell_uv = offset;
    output.glyph_index = cell.glyph_index;

    return output;
}

float4 PSMain(VS_OUTPUT input) : SV_TARGET {
    // For now, just return the background color.
    // Glyph atlas sampling will be added in a later task.
    return input.bg_color;
}
