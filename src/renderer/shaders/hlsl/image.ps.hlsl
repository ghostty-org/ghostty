#include "common.hlsl"

Texture2D image_tex : register(t1);
SamplerState image_sampler : register(s0);

struct PSInput {
    float4 position : SV_Position;
    float2 tex_coord : TEXCOORD0;
};

float4 ps_main(PSInput input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    float4 rgba = image_tex.Sample(image_sampler, input.tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= float3(rgba.a, rgba.a, rgba.a);

    return rgba;
}
