#include "common.hlsl"

// Atlas textures - accessed with pixel coordinates via Load().
Texture2D atlas_grayscale : register(t1);
Texture2D atlas_color : register(t2);

static const uint ATLAS_GRAYSCALE = 0u;
static const uint ATLAS_COLOR = 1u;

struct PSInput {
    float4 position            : SV_Position;
    nointerpolation uint atlas : ATLAS;
    nointerpolation float4 color : COLOR;
    nointerpolation float4 bg_color : BG_COLOR;
    float2 tex_coord           : TEXCOORD0;
};

float4 ps_main(PSInput input) : SV_Target {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;
    bool use_linear_correction = (bools & USE_LINEAR_CORRECTION) != 0;

    if (input.atlas == ATLAS_GRAYSCALE) {
        // Our input color is always linear.
        float4 color = input.color;

        // If we're not doing linear blending, re-apply gamma encoding.
        if (!use_linear_blending) {
            color.rgb /= float3(color.a, color.a, color.a);
            color = unlinearize(color);
            color.rgb *= float3(color.a, color.a, color.a);
        }

        // Fetch alpha mask using pixel coordinates (Load).
        float a = atlas_grayscale.Load(int3(int2(input.tex_coord), 0)).r;

        // Linear blending weight correction.
        if (use_linear_correction) {
            float4 bg = input.bg_color;
            float fg_l = luminance(color.rgb);
            float bg_l = luminance(bg.rgb);
            if (abs(fg_l - bg_l) > 0.001) {
                float blend_l = linearize_f(unlinearize_f(fg_l) * a + unlinearize_f(bg_l) * (1.0 - a));
                a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
            }
        }

        color *= a;
        return color;
    } else {
        // ATLAS_COLOR: color glyphs are premultiplied linear colors.
        float4 color = atlas_color.Load(int3(int2(input.tex_coord), 0));

        if (use_linear_blending) {
            return color;
        }

        // Unlinearize for non-linear blending.
        color.rgb /= float3(color.a, color.a, color.a);
        color = unlinearize(color);
        color.rgb *= float3(color.a, color.a, color.a);
        return color;
    }
}
