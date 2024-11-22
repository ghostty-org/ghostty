#version 300 es

in vec2 grid_pos;
in vec2 cell_offset;
in vec4 source_rect;
in vec2 dest_size;

out vec2 tex_coord;

uniform sampler2D image;
uniform vec2 cell_size;
uniform mat4 projection;

void main() {
    // The size of the image in pixels
    vec2 image_size = vec2(textureSize(image, 0));

    // Turn the cell position into a vertex point depending on the
    // gl_VertexID. Since we use instanced drawing, we have 4 vertices
    // for each corner of the cell. We can use gl_VertexID to determine
    // which one we're looking at. Using this, we can use 1 or 0 to keep
    // or discard the value for the vertex.
    //
    // 0 = top-right
    // 1 = bot-right
    // 2 = bot-left
    // 3 = top-left
    vec2 position;
    position.x = (gl_VertexID == 0 || gl_VertexID == 1) ? 1. : 0.;
    position.y = (gl_VertexID == 0 || gl_VertexID == 3) ? 0. : 1.;

    // The texture coordinates start at our source x/y, then add the width/height
    // as enabled by our instance id, then normalize to [0, 1]
    tex_coord = source_rect.xy;
    tex_coord += source_rect.zw * position;
    tex_coord /= image_size;

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    vec2 image_pos = (cell_size * grid_pos) + cell_offset;
    image_pos += dest_size * position;

    gl_Position = projection * vec4(image_pos.xy, 0, 1.0);
}
