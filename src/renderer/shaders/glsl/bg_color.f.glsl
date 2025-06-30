#include "common.glsl"

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    out_FragColor = load_color(
            unpack4u8(bg_color_packed_4u8),
            use_linear_blending
        );
}
