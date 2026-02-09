#include "common.hlsl"

Texture2D image_tex : register(t1);
SamplerState image_sampler : register(s0);

struct PSInput {
    float4 position                       : SV_Position;
    nointerpolation float4 bg_color       : BG_COLOR;
    nointerpolation float2 offset         : OFFSET;
    nointerpolation float2 scale          : SCALE;
    nointerpolation float  opacity        : OPACITY;
    nointerpolation uint   repeat_flag    : REPEAT;
};

float4 ps_main(PSInput input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // SV_Position already has upper-left origin in D3D11.
    float2 tex_coord = (input.position.xy - input.offset) * input.scale;

    uint tex_w, tex_h;
    image_tex.GetDimensions(tex_w, tex_h);
    float2 tex_size = float2(tex_w, tex_h);

    // Repeat wrapping.
    if (input.repeat_flag != 0) {
        tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
    }

    float4 rgba;
    // Out of bounds check.
    if (any(tex_coord < float2(0.0, 0.0)) || any(tex_coord > tex_size)) {
        rgba = float4(0.0, 0.0, 0.0, 0.0);
    } else {
        // Normalize for sampling.
        rgba = image_tex.Sample(image_sampler, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply by opacity, capped to avoid overexposure.
    rgba *= min(input.opacity, 1.0 / input.bg_color.a);

    // Blend onto fully opaque bg color.
    rgba += max(float4(0.0, 0.0, 0.0, 0.0), float4(input.bg_color.rgb, 1.0) * float4(1.0 - rgba.a, 1.0 - rgba.a, 1.0 - rgba.a, 1.0 - rgba.a));

    // Multiply by bg alpha.
    rgba *= input.bg_color.a;

    return rgba;
}
