#version 300 es

in mediump vec2 tex_coord;

out mediump vec4 out_FragColor;

uniform sampler2D image;

void main() {
    mediump vec4 color = texture(image, tex_coord);
    out_FragColor = vec4(color.rgb * color.a, color.a);
}
