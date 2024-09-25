#version 330 core

in vec2 glyph_tex_coords;
flat in uint mode;

// The color for this cell. If this is a background pass this is the
// background color. Otherwise, this is the foreground color.
flat in vec4 color;

// The position of the cells top-left corner.
flat in vec2 screen_cell_pos;

// Position the fragment coordinate to the upper left
layout(origin_upper_left) in vec4 gl_FragCoord;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

// Font texture
uniform sampler2D text;
uniform sampler2D text_color;

// Dimensions of the cell
uniform vec2 cell_size;
uniform bool blink_visible;

// See vertex shader
const uint MODE_FG             = 1u;
const uint MODE_FG_CONSTRAINED = 2u;
const uint MODE_FG_COLOR       = 4u;
const uint MODE_FG_POWERLINE   = 8u;
const uint MODE_FG_BLINK       = 16u;

void main() {
    if ((mode & MODE_FG) == 0u) {
      // Background
      out_FragColor = color;
    }
    if ((mode & MODE_FG_BLINK) != 0u && !blink_visible) {
        discard;
    }
    if ((mode & MODE_FG_COLOR) != 0u) {
        out_FragColor = texture(text_color, glyph_tex_coords);
        return;
    }

    float a = texture(text, glyph_tex_coords).r;
    vec3 premult = color.rgb * color.a;
    out_FragColor = vec4(premult.rgb*a, a);
}
