#include <metal_stdlib>

using namespace metal;

enum Padding : uint8_t {
  EXTEND_LEFT = 1u,
  EXTEND_RIGHT = 2u,
  EXTEND_UP = 4u,
  EXTEND_DOWN = 8u,
};

struct Uniforms {
  float4x4 projection_matrix;
  float2 cell_size;
  ushort2 grid_size;
  float4 grid_padding;
  uint8_t padding_extend;
  float min_contrast;
  ushort2 cursor_pos;
  uchar4 cursor_color;
  bool blink_visible;
};

//-------------------------------------------------------------------
// Color Functions
//-------------------------------------------------------------------
#pragma mark - Colors

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#relativeluminancedef
float luminance_component(float c) {
  if (c <= 0.03928f) {
    return c / 12.92f;
  } else {
    return pow((c + 0.055f) / 1.055f, 2.4f);
  }
}

float relative_luminance(float3 color) {
  color.r = luminance_component(color.r);
  color.g = luminance_component(color.g);
  color.b = luminance_component(color.b);
  float3 weights = float3(0.2126f, 0.7152f, 0.0722f);
  return dot(color, weights);
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
float contrast_ratio(float3 color1, float3 color2) {
  float l1 = relative_luminance(color1);
  float l2 = relative_luminance(color2);
  return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
float4 contrasted_color(float min, float4 fg, float4 bg) {
  float3 fg_premult = fg.rgb * fg.a;
  float3 bg_premult = bg.rgb * bg.a;
  float ratio = contrast_ratio(fg_premult, bg_premult);
  if (ratio < min) {
    float white_ratio = contrast_ratio(float3(1.0f), bg_premult);
    float black_ratio = contrast_ratio(float3(0.0f), bg_premult);
    if (white_ratio > black_ratio) {
      return float4(1.0f);
    } else {
      return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
  }

  return fg;
}

//-------------------------------------------------------------------
// Full Screen Vertex Shader
//-------------------------------------------------------------------
#pragma mark - Full Screen Vertex Shader

struct FullScreenVertexOut {
  float4 position [[position]];
};

vertex FullScreenVertexOut full_screen_vertex(
  uint vid [[vertex_id]]
) {
  FullScreenVertexOut out;

  float4 position;
  position.x = (vid == 2) ? 3.0 : -1.0;
  position.y = (vid == 0) ? -3.0 : 1.0;
  position.zw = 1.0;

  // Single triangle is clipped to viewport.
  //
  // X <- vid == 0: (-1, -3)
  // |\
  // | \
  // |  \
  // |###\
  // |#+# \ `+` is (0, 0). `#`s are viewport area.
  // |###  \
  // X------X <- vid == 2: (3, 1)
  // ^
  // vid == 1: (-1, 1)

  out.position = position;

  return out;
}

//-------------------------------------------------------------------
// Cell Background Shader
//-------------------------------------------------------------------
#pragma mark - Cell BG Shader

fragment float4 cell_bg_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant uchar4 *cells [[buffer(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));

  // Clamp x position, extends edge bg colors in to padding on sides.
  if (grid_pos.x < 0) {
    if (uniforms.padding_extend & EXTEND_LEFT) {
      grid_pos.x = 0;
    } else {
      return float4(0.0);
    }
  } else if (grid_pos.x > uniforms.grid_size.x - 1) {
    if (uniforms.padding_extend & EXTEND_RIGHT) {
      grid_pos.x = uniforms.grid_size.x - 1;
    } else {
      return float4(0.0);
    }
  }

  // Clamp y position if we should extend, otherwise discard if out of bounds.
  if (grid_pos.y < 0) {
    if (uniforms.padding_extend & EXTEND_UP) {
      grid_pos.y = 0;
    } else {
      return float4(0.0);
    }
  } else if (grid_pos.y > uniforms.grid_size.y - 1) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      grid_pos.y = uniforms.grid_size.y - 1;
    } else {
      return float4(0.0);
    }
  }

  // Retrieve color for cell and return it.
  return float4(cells[grid_pos.y * uniforms.grid_size.x + grid_pos.x]) / 255.0;
}

//-------------------------------------------------------------------
// Cell Text Shader
//-------------------------------------------------------------------
#pragma mark - Cell Text Shader

// The possible modes that a cell fg entry can take.
enum CellTextMode : uint8_t {
  MODE_TEXT = 1u,
  MODE_TEXT_CONSTRAINED = 2u,
  MODE_TEXT_COLOR = 4u,
  MODE_TEXT_CURSOR = 8u,
  MODE_TEXT_POWERLINE = 16u,
  MODE_TEXT_BLINK = 32u,
};

struct CellTextVertexIn {
  // The position of the glyph in the texture (x, y)
  uint2 glyph_pos [[attribute(0)]];

  // The size of the glyph in the texture (w, h)
  uint2 glyph_size [[attribute(1)]];

  // The left and top bearings for the glyph (x, y)
  int2 bearings [[attribute(2)]];

  // The grid coordinates (x, y) where x < columns and y < rows
  ushort2 grid_pos [[attribute(3)]];

  // The color of the rendered text glyph.
  uchar4 color [[attribute(4)]];

  // The mode for this cell.
  uint8_t mode [[attribute(5)]];

  // The width to constrain the glyph to, in cells, or 0 for no constraint.
  uint8_t constraint_width [[attribute(6)]];
};

struct CellTextVertexOut {
  float4 position [[position]];
  uint8_t mode;
  float4 color;
  float2 tex_coord;
};

vertex CellTextVertexOut cell_text_vertex(
  uint vid [[vertex_id]],
  CellTextVertexIn in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]],
  constant uchar4 *bg_colors [[buffer(2)]]
) {
  // Convert the grid x, y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * float2(in.grid_pos);

  // Turn the cell position into a vertex point depending on the
  // vertex ID. Since we use instanced drawing, we have 4 vertices
  // for each corner of the cell. We can use vertex ID to determine
  // which one we're looking at. Using this, we can use 1 or 0 to keep
  // or discard the value for the vertex.
  //
  // 0 = top-right
  // 1 = bot-right
  // 2 = bot-left
  // 3 = top-left
  float2 corner;
  corner.x = (vid == 0 || vid == 1) ? 1.0f : 0.0f;
  corner.y = (vid == 0 || vid == 3) ? 0.0f : 1.0f;

  CellTextVertexOut out;
  out.mode = in.mode;
  out.color = float4(in.color) / 255.0f;

  //              === Grid Cell ===
  //
  //    offset.x = bearings.x
  //                  .|.
  //                  | |
  //                  +-------+_.
  //                ._|       | |
  //                | | .###. | |
  //                | | #...# | +- bearings.y
  //  glyph_size.y -+ | ##### | |
  //                | | #.... | |
  //   ^            |_| .#### |_| _.
  //   |              |       |    +- offset.y = cell_size.y - bearings.y
  //   .  cell_pos -> +-------+   -'
  // +Y.                |_._|
  //   .                  |
  //   |             glyph_size.x
  // 0,0--...->
  //      +X
  //
  // In order to get the bottom left of the glyph, we compute an offset based
  // on the bearings. The Y bearing is the distance from the top of the cell
  // to the bottom of the glyph, so we subtract it from the cell height to get
  // the y offset. The X bearing is the distance from the left of the cell to
  // the left of the glyph, so it works as the x offset directly.

  float2 size = float2(in.glyph_size);
  float2 offset = float2(in.bearings);

  offset.y = uniforms.cell_size.y - offset.y;

  // If we're constrained then we need to scale the glyph.
  // We also always constrain colored glyphs since we should have
  // their scaled cell size exactly correct.
  if (in.mode & (MODE_TEXT_CONSTRAINED | MODE_TEXT_COLOR)) {
    float max_width = uniforms.cell_size.x * in.constraint_width;
    if (size.x > max_width) {
      float new_y = size.y * (max_width / size.x);
      offset.y += (size.y - new_y) / 2;
      size.y = new_y;
      size.x = max_width;
    }
  }

  // Calculate the final position of the cell which uses our glyph size
  // and glyph offset to create the correct bounding box for the glyph.
  cell_pos = cell_pos + size * corner + offset;
  out.position =
      uniforms.projection_matrix * float4(cell_pos.x, cell_pos.y, 0.0f, 1.0f);

  // Calculate the texture coordinate in pixels. This is NOT normalized
  // (between 0.0 and 1.0), and does not need to be, since the texture will
  // be sampled with pixel coordinate mode.
  out.tex_coord = float2(in.glyph_pos) + float2(in.glyph_size) * corner;

  // If we have a minimum contrast, we need to check if we need to
  // change the color of the text to ensure it has enough contrast
  // with the background.
  // We only apply this adjustment to "normal" text with MODE_TEXT,
  // since we want color glyphs to appear in their original color
  // and Powerline glyphs to be unaffected (else parts of the line would
  // have different colors as some parts are displayed via background colors).
  if (uniforms.min_contrast > 1.0f && !(in.mode & ~(MODE_TEXT | MODE_TEXT_BLINK))) {
    float4 bg_color = float4(bg_colors[in.grid_pos.y * uniforms.grid_size.x + in.grid_pos.x]) / 255.0f;
    out.color = contrasted_color(uniforms.min_contrast, out.color, bg_color);
  }

  // If this cell is the cursor cell, then we need to change the color.
  if (
    !(in.mode & MODE_TEXT_CURSOR) &&
    in.grid_pos.x == uniforms.cursor_pos.x &&
    in.grid_pos.y == uniforms.cursor_pos.y
  ) {
    out.color = float4(uniforms.cursor_color) / 255.0f;
  }

  return out;
}

fragment float4 cell_text_fragment(
  CellTextVertexOut in [[stage_in]],
  texture2d<float> textureGrayscale [[texture(0)]],
  texture2d<float> textureColor [[texture(1)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_edge,
    filter::nearest
  );

  if (in.mode & MODE_TEXT_COLOR) {
    return textureColor.sample(textureSampler, in.tex_coord);
  }
  if (in.mode & MODE_TEXT_BLINK && !uniforms.blink_visible) {
    discard_fragment();
  }

  // We premult the alpha to our whole color since our blend function
  // uses One/OneMinusSourceAlpha to avoid blurry edges.
  // We first premult our given color.
  float4 premult = float4(in.color.rgb * in.color.a, in.color.a);

  // Then premult the texture color
  float a = textureGrayscale.sample(textureSampler, in.tex_coord).r;
  premult = premult * a;

  return premult;
}
//-------------------------------------------------------------------
// Image Shader
//-------------------------------------------------------------------
#pragma mark - Image Shader

struct ImageVertexIn {
  // The grid coordinates (x, y) where x < columns and y < rows where
  // the image will be rendered. It will be rendered from the top left.
  float2 grid_pos [[attribute(0)]];

  // Offset in pixels from the top-left of the cell to make the top-left
  // corner of the image.
  float2 cell_offset [[attribute(1)]];

  // The source rectangle of the texture to sample from.
  float4 source_rect [[attribute(2)]];

  // The final width/height of the image in pixels.
  float2 dest_size [[attribute(3)]];
};

struct ImageVertexOut {
  float4 position [[position]];
  float2 tex_coord;
};

vertex ImageVertexOut image_vertex(
  uint vid [[vertex_id]],
  ImageVertexIn in [[stage_in]],
  texture2d<uint> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  // The size of the image in pixels
  float2 image_size = float2(image.get_width(), image.get_height());

  // Turn the image position into a vertex point depending on the
  // vertex ID. Since we use instanced drawing, we have 4 vertices
  // for each corner of the cell. We can use vertex ID to determine
  // which one we're looking at. Using this, we can use 1 or 0 to keep
  // or discard the value for the vertex.
  //
  // 0 = top-right
  // 1 = bot-right
  // 2 = bot-left
  // 3 = top-left
  float2 corner;
  corner.x = (vid == 0 || vid == 1) ? 1.0f : 0.0f;
  corner.y = (vid == 0 || vid == 3) ? 0.0f : 1.0f;

  // The texture coordinates start at our source x/y, then add the width/height
  // as enabled by our instance id, then normalize to [0, 1]
  float2 tex_coord = in.source_rect.xy;
  tex_coord += in.source_rect.zw * corner;
  tex_coord /= image_size;

  ImageVertexOut out;

  // The position of our image starts at the top-left of the grid cell and
  // adds the source rect width/height components.
  float2 image_pos = (uniforms.cell_size * in.grid_pos) + in.cell_offset;
  image_pos += in.dest_size * corner;

  out.position =
      uniforms.projection_matrix * float4(image_pos.x, image_pos.y, 0.0f, 1.0f);
  out.tex_coord = tex_coord;
  return out;
}

fragment float4 image_fragment(
  ImageVertexOut in [[stage_in]],
  texture2d<uint> image [[texture(0)]]
) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  // Ehhhhh our texture is in RGBA8Uint but our color attachment is
  // BGRA8Unorm. So we need to convert it. We should really be converting
  // our texture to BGRA8Unorm.
  uint4 rgba = image.sample(textureSampler, in.tex_coord);

  // Convert to float4 and premultiply the alpha. We should also probably
  // premultiply the alpha in the texture.
  float4 result = float4(rgba) / 255.0f;
  result.rgb *= result.a;
  return result;
}

