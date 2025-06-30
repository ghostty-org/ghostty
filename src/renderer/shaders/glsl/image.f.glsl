#include "common.glsl"

layout(binding = 0) uniform sampler2D image;

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    vec4 rgba = texture(image, tex_coord);

    if (!use_linear_blending) {
        rgba = unlinearize(rgba);
    }

    rgba.rgb *= vec3(rgba.a);

    out_FragColor = rgba;
}
