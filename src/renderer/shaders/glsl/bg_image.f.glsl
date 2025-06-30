#include "common.glsl"

// Position the FragCoord origin to the upper left
// so as to align with our texture's directionality.
layout(origin_upper_left) in vec4 gl_FragCoord;

layout(binding = 0) uniform sampler2D image;

flat in vec4 bg_color;
flat in vec2 offset;
flat in vec2 scale;
flat in float opacity;
flat in uint repeat;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Our texture coordinate is based on the screen position, offset by the
    // dest rect origin, and scaled by the ratio between the dest rect size
    // and the original texture size, which effectively scales the original
    // size of the texture to the dest rect size.
    vec2 tex_coord = (gl_FragCoord.xy - offset) * scale;

    vec2 tex_size = textureSize(image, 0);

    // If we need to repeat the texture, wrap the coordinates.
    if (repeat != 0) {
        tex_coord = mod(mod(tex_coord, tex_size) + tex_size, tex_size);
    }

    vec4 rgba;
    // If we're out of bounds, we have no color,
    // otherwise we sample the texture for it.
    if (any(lessThan(tex_coord, vec2(0.0))) ||
            any(greaterThan(tex_coord, tex_size)))
    {
        rgba = vec4(0.0);
    } else {
        // We divide by the texture size to normalize for sampling.
        rgba = texture(image, tex_coord / tex_size);

        if (!use_linear_blending) {
            rgba = unlinearize(rgba);
        }

        rgba.rgb *= rgba.a;
    }

    // Multiply it by the configured opacity, but cap it at
    // the value that will make it fully opaque relative to
    // the background color alpha, so it isn't overexposed.
    rgba *= min(opacity, 1.0 / bg_color.a);

    // Blend it on to a fully opaque version of the background color.
    rgba += max(vec4(0.0), vec4(bg_color.rgb, 1.0) * vec4(1.0 - rgba.a));

    // Multiply everything by the background color alpha.
    rgba *= bg_color.a;

    out_FragColor = rgba;
}
