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

// See vertex shader
const uint MODE_BG = 1u;
const uint MODE_FG = 2u;
const uint MODE_FG_COLOR = 7u;
const uint MODE_STRIKETHROUGH = 8u;

#include customFragfilter

void main() {
    float a;

    switch (mode) {
    case MODE_BG:
        out_FragColor = color;
        break;

    case MODE_FG:
        a = texture(text, glyph_tex_coords).r;
        vec3 premult = color.rgb * color.a;
        out_FragColor = vec4(premult.rgb*a, a);
        break;

    case MODE_FG_COLOR:
        out_FragColor = texture(text_color, glyph_tex_coords);
        break;

    case MODE_STRIKETHROUGH:
        out_FragColor = color;
        break;
    }

    CustomFilterFrag(out_FragColor);
}
