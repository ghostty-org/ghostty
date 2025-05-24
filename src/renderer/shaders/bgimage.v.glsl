#version 330 core

// These are the possible modes that "mode" can be set to.
//
// NOTE: this must be kept in sync with the BackgroundImageMode
const uint MODE_CONTAIN = 0u;
const uint MODE_FILL = 1u;
const uint MODE_COVER = 2u;
const uint MODE_TILED = 3u;
const uint MODE_NONE = 4u;

layout (location = 0) in vec2 terminal_size;
layout (location = 1) in uint mode;
layout (location = 2) in uint position_index;

out vec2 tex_coord;

uniform sampler2D image;
uniform mat4 projection;

void main() {
	// Calculate the position of the image
	vec2 position;
	position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
	position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;

	// Get the size of the image
	vec2 image_size = textureSize(image, 0);

	// Handles the scale of the image relative to the terminal size
	vec2 scale = vec2(1.0, 1.0);

	// Calculate the aspect ratio of the terminal and the image
	vec2 aspect_ratio = vec2(
		terminal_size.x / terminal_size.y,
		image_size.x / image_size.y
	);

	switch (mode) {
	case MODE_CONTAIN:
		// If zoomed, we want to scale the image to fit the terminal
		if (aspect_ratio.x > aspect_ratio.y) {
			scale.x = aspect_ratio.y / aspect_ratio.x;
		}
		else {
			scale.y = aspect_ratio.x / aspect_ratio.y;
		}
		break;
	case MODE_COVER:
		// If cropped, we want to scale the image to fit the terminal
		if (aspect_ratio.x < aspect_ratio.y) {
			scale.x = aspect_ratio.y / aspect_ratio.x;
		}
		else {
			scale.y = aspect_ratio.x / aspect_ratio.y;
		}
		break;
	case MODE_NONE:
		// If none, the final scale of the image should match the actual
		// size of the image and should be centered
		scale.x = image_size.x / terminal_size.x;
		scale.y = image_size.y / terminal_size.y;
		break;
	case MODE_FILL:
	case MODE_TILED:
		// We don't need to do anything for stretched or tiled
		break;
	}

	vec2 final_image_size = terminal_size * position * scale;
	vec2 offset = vec2(0.0, 0.0);

	uint y_pos = position_index / 3u; // 0 = top, 1 = center, 2 = bottom
	uint x_pos = position_index % 3u; // 0 = left, 1 = center, 2 = right
	offset = ((terminal_size * (1.0 - scale)) / 2.0) * vec2(x_pos, y_pos);
	gl_Position = projection * vec4(final_image_size.xy + offset, 0.0, 1.0);
	tex_coord = position;
	if (mode == MODE_TILED) {
		tex_coord = position * terminal_size / image_size;
	}
}
