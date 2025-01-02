#version 330 core

const uint MODE_ZOOMED = 0u;
const uint MODE_STRETCHED = 1u;
const uint MODE_TILED = 2u;
const uint MODE_CENTERED = 3u;

in vec2 tex_coord;
flat in uint mode;

layout(location = 0) out vec4 out_FragColor;

uniform sampler2D image;
uniform float opacity;

void main() {
	// Normalize the coordinate if we are tiling
	vec2 norm_coord = tex_coord;
	// if (mode == MODE_TILED) {
	// 	norm_coord = fract(tex_coord);
	// }
	norm_coord = fract(tex_coord);
	vec4 color = texture(image, norm_coord);
	out_FragColor = vec4(color.rgb * color.a * opacity, color.a * opacity);
}
