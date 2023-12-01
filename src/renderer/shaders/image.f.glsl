#version 330 core

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

uniform sampler2D image;

void main() {
    out_FragColor = texture(image, tex_coord);
}
