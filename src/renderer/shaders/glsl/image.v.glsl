#include "common.glsl"

layout(binding = 0) uniform sampler2D image;

layout(location = 0) in vec2 grid_pos;
layout(location = 1) in vec2 cell_offset;
layout(location = 2) in vec4 source_rect;
layout(location = 3) in vec2 dest_size;

out vec2 tex_coord;

void main() {
    int vid = gl_VertexID;

    // We use a triangle strip with 4 vertices to render quads,
    // so we determine which corner of the cell this vertex is in
    // based on the vertex ID.
    //
    //   0 --> 1
    //   |   .'|
    //   |  /  |
    //   | L   |
    //   2 --> 3
    //
    // 0 = top-left  (0, 0)
    // 1 = top-right (1, 0)
    // 2 = bot-left  (0, 1)
    // 3 = bot-right (1, 1)
    vec2 corner;
    corner.x = float(vid == 1 || vid == 3);
    corner.y = float(vid == 2 || vid == 3);

    // The texture coordinates start at our source x/y
    // and add the width/height depending on the corner.
    tex_coord = source_rect.xy;
    tex_coord += source_rect.zw * corner;

    // Normalize the coordinates.
    tex_coord /= textureSize(image, 0);

    // The position of our image starts at the top-left of the grid cell and
    // adds the source rect width/height components.
    vec2 image_pos = (cell_size * grid_pos) + cell_offset;
    image_pos += dest_size * corner;

    gl_Position = projection_matrix * vec4(image_pos.xy, 1.0, 1.0);
}
