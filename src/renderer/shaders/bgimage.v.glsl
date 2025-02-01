#version 330 core

// These are the possible modes that "mode" can be set to.
//
// NOTE: this must be kept in sync with the BackgroundImageMode
const uint MODE_ZOOMED = 0u;
const uint MODE_STRETCHED = 1u;
const uint MODE_CROPPED = 2u;
const uint MODE_TILED = 3u;
const uint MODE_CENTERED = 4u;
const uint MODE_UPPER_LEFT = 5u;
const uint MODE_UPPER_RIGHT = 6u;
const uint MODE_LOWER_LEFT = 7u;
const uint MODE_LOWER_RIGHT = 8u;

layout (location = 0) in vec2 terminal_size;
layout (location = 1) in uint mode;

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
	case MODE_ZOOMED:
		// If zoomed, we want to scale the image to fit the terminal
		if (aspect_ratio.x > aspect_ratio.y) {
			scale.x = aspect_ratio.y / aspect_ratio.x;
		}
		else {
			scale.y = aspect_ratio.x / aspect_ratio.y;
		}
		break;
	case MODE_CROPPED:
		// If cropped, we want to scale the image to fit the terminal
		if (aspect_ratio.x < aspect_ratio.y) {
			scale.x = aspect_ratio.y / aspect_ratio.x;
		}
		else {
			scale.y = aspect_ratio.x / aspect_ratio.y;
		}
		break;
	case MODE_CENTERED:
	case MODE_UPPER_LEFT:
	case MODE_UPPER_RIGHT:
	case MODE_LOWER_LEFT:
	case MODE_LOWER_RIGHT:
		// If centered, the final scale of the image should match the actual
		// size of the image and should be centered
		scale.x = image_size.x / terminal_size.x;
		scale.y = image_size.y / terminal_size.y;
		break;
	case MODE_STRETCHED:
	case MODE_TILED:
		// We don't need to do anything for stretched or tiled
		break;
	}

	vec2 final_image_size = terminal_size * position * scale;
	vec2 offset = vec2(0.0, 0.0);
	switch (mode) {
	case MODE_ZOOMED:
	case MODE_STRETCHED:
	case MODE_CROPPED:
	case MODE_TILED:
	case MODE_CENTERED:
		offset = (terminal_size * (1.0 - scale)) / 2.0;
		break;
	case MODE_UPPER_LEFT:
		offset = vec2(0.0, 0.0);
		break;
	case MODE_UPPER_RIGHT:
		offset = vec2(terminal_size.x - image_size.x, 0.0);
		break;
	case MODE_LOWER_LEFT:
		offset = vec2(0.0, terminal_size.y - image_size.y);
		break;
	case MODE_LOWER_RIGHT:
		offset = vec2(terminal_size.x - image_size.x, terminal_size.y - image_size.y);
		break;
	}
	gl_Position = projection * vec4(final_image_size.xy + offset, 0.0, 1.0);
	tex_coord = position;
	if (mode == MODE_TILED) {
		tex_coord = position * terminal_size / image_size;
	}
}
