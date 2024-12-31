#version 330 core

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

uniform sampler2D image;
uniform float opacity;

void main() {
	vec4 color = texture(image, tex_coord);
	out_FragColor = vec4(color.rgb * color.a * opacity, color.a * opacity);
}
