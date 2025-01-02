#version 330 core

in vec2 tex_coord;

layout(location = 0) out vec4 out_FragColor;

uniform sampler2D image;
uniform float opacity;

void main() {
	// Normalize the coordinates
	vec2 norm_coord = tex_coord;
	norm_coord = fract(tex_coord);
	vec4 color = texture(image, norm_coord);
	out_FragColor = vec4(color.rgb * color.a * opacity, color.a * opacity);
}
