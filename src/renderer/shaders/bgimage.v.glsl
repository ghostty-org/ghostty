#version 330 core

const uint MODE_ASPECT = 0u;
const uint MODE_SCALED = 1u;

layout (location = 0) in vec2 terminal_size;
layout (location = 1) in uint mode;

out vec2 tex_coord;
uniform sampler2D image;
uniform mat4 projection;

void main() {
	vec2 position;
	position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
	position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;

	vec2 image_size = textureSize(image, 0);
	vec2 scale = vec2(1.0, 1.0);
	switch (mode) {
	case MODE_ASPECT:
		vec2 aspect_ratio = vec2(
			terminal_size.x / terminal_size.y,
			image_size.x / image_size.y
		);
		if (aspect_ratio.x > aspect_ratio.y) {
			scale.x = aspect_ratio.y / aspect_ratio.x;
		}
		else {
			scale.y = aspect_ratio.x / aspect_ratio.y;
		}
	case MODE_SCALED:
		break;
	}

	vec2 image_pos = terminal_size * position * scale;
	vec2 offset = (terminal_size * (1.0 - scale)) / 2.0;
	gl_Position = projection * vec4(image_pos.xy + offset, 0.0, 1.0);
	tex_coord = position;
}
