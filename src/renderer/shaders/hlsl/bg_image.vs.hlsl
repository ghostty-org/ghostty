#include "common.hlsl"

Texture2D image_tex : register(t1);

// Position constants (4 bits).
static const uint BG_IMAGE_POSITION = 15u;
static const uint BG_IMAGE_TL = 0u;
static const uint BG_IMAGE_TC = 1u;
static const uint BG_IMAGE_TR = 2u;
static const uint BG_IMAGE_ML = 3u;
static const uint BG_IMAGE_MC = 4u;
static const uint BG_IMAGE_MR = 5u;
static const uint BG_IMAGE_BL = 6u;
static const uint BG_IMAGE_BC = 7u;
static const uint BG_IMAGE_BR = 8u;

// Fit constants (2 bits shifted 4).
static const uint BG_IMAGE_FIT = 3u << 4;
static const uint BG_IMAGE_CONTAIN = 0u << 4;
static const uint BG_IMAGE_COVER = 1u << 4;
static const uint BG_IMAGE_STRETCH = 2u << 4;
static const uint BG_IMAGE_NO_FIT = 3u << 4;

// Repeat (1 bit shifted 6).
static const uint BG_IMAGE_REPEAT = 1u << 6;

struct VSInput {
    float in_opacity : OPACITY;
    uint  info       : INFO;
    uint  vid        : SV_VertexID;
};

struct VSOutput {
    float4 position                       : SV_Position;
    nointerpolation float4 bg_color       : BG_COLOR;
    nointerpolation float2 offset         : OFFSET;
    nointerpolation float2 scale          : SCALE;
    nointerpolation float  opacity        : OPACITY;
    nointerpolation uint   repeat_flag    : REPEAT;
};

VSOutput vs_main(VSInput input) {
    VSOutput output;

    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Full-screen triangle.
    output.position.x = (input.vid == 2) ? 3.0 : -1.0;
    output.position.y = (input.vid == 0) ? -3.0 : 1.0;
    output.position.z = 1.0;
    output.position.w = 1.0;

    output.opacity = input.in_opacity;
    output.repeat_flag = input.info & BG_IMAGE_REPEAT;

    uint tex_w, tex_h;
    image_tex.GetDimensions(tex_w, tex_h);
    float2 tex_size = float2(tex_w, tex_h);

    float2 dest_size = tex_size;
    uint fit = input.info & BG_IMAGE_FIT;
    if (fit == BG_IMAGE_CONTAIN) {
        float s = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_COVER) {
        float s = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
        dest_size = tex_size * s;
    } else if (fit == BG_IMAGE_STRETCH) {
        dest_size = screen_size;
    }
    // BG_IMAGE_NO_FIT: dest_size stays as tex_size.

    float2 start_pos = float2(0.0, 0.0);
    float2 mid = (screen_size - dest_size) / float2(2.0, 2.0);
    float2 end_pos = screen_size - dest_size;

    float2 dest_offset = mid;
    uint pos = input.info & BG_IMAGE_POSITION;
    if (pos == BG_IMAGE_TL) dest_offset = float2(start_pos.x, start_pos.y);
    else if (pos == BG_IMAGE_TC) dest_offset = float2(mid.x, start_pos.y);
    else if (pos == BG_IMAGE_TR) dest_offset = float2(end_pos.x, start_pos.y);
    else if (pos == BG_IMAGE_ML) dest_offset = float2(start_pos.x, mid.y);
    else if (pos == BG_IMAGE_MC) dest_offset = float2(mid.x, mid.y);
    else if (pos == BG_IMAGE_MR) dest_offset = float2(end_pos.x, mid.y);
    else if (pos == BG_IMAGE_BL) dest_offset = float2(start_pos.x, end_pos.y);
    else if (pos == BG_IMAGE_BC) dest_offset = float2(mid.x, end_pos.y);
    else if (pos == BG_IMAGE_BR) dest_offset = float2(end_pos.x, end_pos.y);

    output.offset = dest_offset;
    output.scale = tex_size / dest_size;

    // Load bg color with full opacity for blending, store original alpha separately.
    uint4 u_bg_color = unpack4u8(bg_color_packed_4u8);
    output.bg_color = float4(load_color(
        uint4(u_bg_color.rgb, 255),
        use_linear_blending
    ).rgb, float(u_bg_color.a) / 255.0);

    return output;
}
