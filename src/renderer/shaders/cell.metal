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
  uchar4 bg_color;
  bool cursor_wide;
  bool use_display_p3;
  bool use_linear_blending;
  bool use_linear_correction;
};

//-------------------------------------------------------------------
// Color Functions
//-------------------------------------------------------------------
#pragma mark - Colors

// D50-adapted sRGB to XYZ conversion matrix.
// http://www.brucelindbloom.com/Eqn_RGB_XYZ_Matrix.html
constant float3x3 sRGB_XYZ = transpose(float3x3(
  0.4360747, 0.3850649, 0.1430804,
  0.2225045, 0.7168786, 0.0606169,
  0.0139322, 0.0971045, 0.7141733
));
// XYZ to Display P3 conversion matrix.
// http://endavid.com/index.php?entry=79
constant float3x3 XYZ_DP3 = transpose(float3x3(
  2.40414768,-0.99010704,-0.39759019,
 -0.84239098, 1.79905954, 0.01597023,
  0.04838763,-0.09752546, 1.27393636
));
// By composing the two above matrices we get
// our sRGB to Display P3 conversion matrix.
constant float3x3 sRGB_DP3 = XYZ_DP3 * sRGB_XYZ;

// Converts a color in linear sRGB to linear Display P3
//
// TODO: The color matrix should probably be computed
//       dynamically and passed as a uniform, rather
//       than being hard coded above.
float3 srgb_to_display_p3(float3 srgb) {
  return sRGB_DP3 * srgb;
}

// Converts a color from sRGB gamma encoding to linear.
float4 linearize(float4 srgb) {
  bool3 cutoff = srgb.rgb <= 0.04045;
  float3 lower = srgb.rgb / 12.92;
  float3 higher = pow((srgb.rgb + 0.055) / 1.055, 2.4);
  srgb.rgb = mix(higher, lower, float3(cutoff));

  return srgb;
}
float linearize(float v) {
  return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
float4 unlinearize(float4 linear) {
  bool3 cutoff = linear.rgb <= 0.0031308;
  float3 lower = linear.rgb * 12.92;
  float3 higher = pow(linear.rgb, 1.0 / 2.4) * 1.055 - 0.055;
  linear.rgb = mix(higher, lower, float3(cutoff));

  return linear;
}
float unlinearize(float v) {
  return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(float3 color) {
  return dot(color, float3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(float3 color1, float3 color2) {
  float l1 = luminance(color1);
  float l2 = luminance(color2);
  return (max(l1, l2) + 0.05f) / (min(l1, l2) + 0.05f);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float4 contrasted_color(float min, float4 fg, float4 bg) {
  float ratio = contrast_ratio(fg.rgb, bg.rgb);
  if (ratio < min) {
    float white_ratio = contrast_ratio(float3(1.0f), bg.rgb);
    float black_ratio = contrast_ratio(float3(0.0f), bg.rgb);
    if (white_ratio > black_ratio) {
      return float4(1.0f);
    } else {
      return float4(0.0f, 0.0f, 0.0f, 1.0f);
    }
  }

  return fg;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// Returns a color in the Display P3 color space.
//
// If `display_p3` is true, then the provided color is assumed to
// already be in the Display P3 color space, otherwise it's treated
// as an sRGB color and is appropriately converted to Display P3.
//
// `linear` controls whether the returned color is linear or gamma encoded.
float4 load_color(
  uchar4 in_color,
  bool display_p3,
  bool linear
) {
  // 0 .. 255 -> 0.0 .. 1.0
  float4 color = float4(in_color) / 255.0f;

  // If our color is already in Display P3 and
  // we aren't doing linear blending, then we
  // already have the correct color here and
  // can premultiply and return it.
  if (display_p3 && !linear) {
    color.rgb *= color.a;
    return color;
  }

  // The color is in either the sRGB or Display P3 color space,
  // so in either case, it's a color space which uses the sRGB
  // transfer function, so we can use one function in order to
  // linearize it in either case.
  //
  // Even if we aren't doing linear blending, the color
  // needs to be in linear space to convert color spaces.
  color = linearize(color);

  // If we're *NOT* using display P3 colors, then we're dealing
  // with an sRGB color, in which case we need to convert it in
  // to the Display P3 color space, since our output is always
  // Display P3.
  if (!display_p3) {
    color.rgb = srgb_to_display_p3(color.rgb);
  }

  // If we're not doing linear blending, then we need to
  // unlinearize after doing the color space conversion.
  if (!linear) {
    color = unlinearize(color);
  }

  // Premultiply our color by its alpha.
  color.rgb *= color.a;

  return color;
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

struct CellBgVertexOut {
  float4 position [[position]];
  float4 bg_color;
};

vertex CellBgVertexOut cell_bg_vertex(
  uint vid [[vertex_id]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  CellBgVertexOut out;

  float4 position;
  position.x = (vid == 2) ? 3.0 : -1.0;
  position.y = (vid == 0) ? -3.0 : 1.0;
  position.zw = 1.0;
  out.position = position;

  // Convert the background color to Display P3
  out.bg_color = load_color(
    uniforms.bg_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );

  return out;
}

fragment float4 cell_bg_fragment(
  CellBgVertexOut in [[stage_in]],
  constant uchar4 *cells [[buffer(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));

  float4 bg = float4(0.0);
  // If we have any background transparency then we render bg-colored cells as
  // fully transparent, since the background is handled by the layer bg color
  // and we don't want to double up our bg color, but if our bg color is fully
  // opaque then our layer is opaque and can't handle transparency, so we need
  // to return the bg color directly instead.
  if (uniforms.bg_color.a == 255) {
    bg = in.bg_color;
  }

  // Clamp x position, extends edge bg colors in to padding on sides.
  if (grid_pos.x < 0) {
    if (uniforms.padding_extend & EXTEND_LEFT) {
      grid_pos.x = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.x > uniforms.grid_size.x - 1) {
    if (uniforms.padding_extend & EXTEND_RIGHT) {
      grid_pos.x = uniforms.grid_size.x - 1;
    } else {
      return bg;
    }
  }

  // Clamp y position if we should extend, otherwise discard if out of bounds.
  if (grid_pos.y < 0) {
    if (uniforms.padding_extend & EXTEND_UP) {
      grid_pos.y = 0;
    } else {
      return bg;
    }
  } else if (grid_pos.y > uniforms.grid_size.y - 1) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      grid_pos.y = uniforms.grid_size.y - 1;
    } else {
      return bg;
    }
  }

  // Load the color for the cell.
  uchar4 cell_color = cells[grid_pos.y * uniforms.grid_size.x + grid_pos.x];

  // We have special case handling for when the cell color matches the bg color.
  if (all(cell_color == uniforms.bg_color)) {
    return bg;
  }

  // Convert the color and return it.
  //
  // TODO: We may want to blend the color with the background
  //       color, rather than purely replacing it, this needs
  //       some consideration about config options though.
  //
  // TODO: It might be a good idea to do a pass before this
  //       to convert all of the bg colors, so we don't waste
  //       a bunch of work converting the cell color in every
  //       fragment of each cell. It's not the most epxensive
  //       operation, but it is still wasted work.
  return load_color(
    cell_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );
}

//-------------------------------------------------------------------
// Cell Text Shader
//-------------------------------------------------------------------
#pragma mark - Cell Text Shader

// The possible modes that a cell fg entry can take.
enum CellTextMode : uint8_t {
  MODE_TEXT = 1u,
  MODE_TEXT_CONSTRAINED = 2u,
  MODE_TEXT_COLOR = 3u,
  MODE_TEXT_CURSOR = 4u,
  MODE_TEXT_POWERLINE = 5u,
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
  uint8_t mode [[flat]];
  float4 color [[flat]];
  float4 bg_color [[flat]];
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

  //              === Grid Cell ===
  //      +X
  // 0,0--...->
  //   |
  //   . offset.x = bearings.x
  // +Y.               .|.
  //   .               | |
  //   |   cell_pos -> +-------+   _.
  //   v             ._|       |_. _|- offset.y = cell_size.y - bearings.y
  //                 | | .###. | |
  //                 | | #...# | |
  //   glyph_size.y -+ | ##### | |
  //                 | | #.... | +- bearings.y
  //                 |_| .#### | |
  //                   |       |_|
  //                   +-------+
  //                     |_._|
  //                       |
  //                  glyph_size.x
  //
  // In order to get the top left of the glyph, we compute an offset based on
  // the bearings. The Y bearing is the distance from the bottom of the cell
  // to the top of the glyph, so we subtract it from the cell height to get
  // the y offset. The X bearing is the distance from the left of the cell
  // to the left of the glyph, so it works as the x offset directly.

  float2 size = float2(in.glyph_size);
  float2 offset = float2(in.bearings);

  offset.y = uniforms.cell_size.y - offset.y;

  // If we're constrained then we need to scale the glyph.
  if (in.mode == MODE_TEXT_CONSTRAINED) {
    float max_width = uniforms.cell_size.x * in.constraint_width;
    // If this glyph is wider than the constraint width,
    // fit it to the width and remove its horizontal offset.
    if (size.x > max_width) {
      float new_y = size.y * (max_width / size.x);
      offset.y += (size.y - new_y) / 2;
      offset.x = 0;
      size.y = new_y;
      size.x = max_width;
    } else if (max_width - size.x > offset.x) {
      // However, if it does fit in the constraint width, make
      // sure the offset is small enough to not push it over the
      // right edge of the constraint width.
      offset.x = max_width - size.x;
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

  // Get our color. We always fetch a linearized version to
  // make it easier to handle minimum contrast calculations.
  out.color = load_color(
    in.color,
    uniforms.use_display_p3,
    true
  );

  // Get the BG color
  out.bg_color = load_color(
    bg_colors[in.grid_pos.y * uniforms.grid_size.x + in.grid_pos.x],
    uniforms.use_display_p3,
    true
  );

  // If we have a minimum contrast, we need to check if we need to
  // change the color of the text to ensure it has enough contrast
  // with the background.
  // We only apply this adjustment to "normal" text with MODE_TEXT,
  // since we want color glyphs to appear in their original color
  // and Powerline glyphs to be unaffected (else parts of the line would
  // have different colors as some parts are displayed via background colors).
  if (uniforms.min_contrast > 1.0f && in.mode == MODE_TEXT) {
    // Ensure our minimum contrast
    out.color = contrasted_color(uniforms.min_contrast, out.color, out.bg_color);
  }

  // Check if current position is under cursor (including wide cursor)
  bool is_cursor_pos = (
      in.grid_pos.x == uniforms.cursor_pos.x ||
      uniforms.cursor_wide &&
        in.grid_pos.x == uniforms.cursor_pos.x + 1
    ) && in.grid_pos.y == uniforms.cursor_pos.y;

  // If this cell is the cursor cell, then we need to change the color.
  if (in.mode != MODE_TEXT_CURSOR && is_cursor_pos) {
    out.color = load_color(
      uniforms.cursor_color,
      uniforms.use_display_p3,
      false
    );
  }

  return out;
}

fragment float4 cell_text_fragment(
  CellTextVertexOut in [[stage_in]],
  texture2d<float> textureGrayscale [[texture(0)]],
  texture2d<float> textureColor [[texture(1)]],
  constant Uniforms& uniforms [[buffer(2)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_edge,
    // TODO(qwerasd): This can be changed back to filter::nearest when
    //                we move the constraint logic out of the GPU code
    //                which should once again guarantee pixel perfect
    //                sizing.
    filter::linear
  );

  switch (in.mode) {
    default:
    case MODE_TEXT_CURSOR:
    case MODE_TEXT_CONSTRAINED:
    case MODE_TEXT_POWERLINE:
    case MODE_TEXT: {
      // Our input color is always linear.
      float4 color = in.color;

      // If we're not doing linear blending, then we need to
      // re-apply the gamma encoding to our color manually.
      //
      // Since the alpha is premultiplied, we need to divide
      // it out before unlinearizing and re-multiply it after.
      if (!uniforms.use_linear_blending) {
        color.rgb /= color.a;
        color = unlinearize(color);
        color.rgb *= color.a;
      }

      // Fetch our alpha mask for this pixel.
      float a = textureGrayscale.sample(textureSampler, in.tex_coord).r;

      // Linear blending weight correction corrects the alpha value to
      // produce blending results which match gamma-incorrect blending.
      if (uniforms.use_linear_correction) {
        // Short explanation of how this works:
        //
        // We get the luminances of the foreground and background colors,
        // and then unlinearize them and perform blending on them. This
        // gives us our desired luminance, which we derive our new alpha
        // value from by mapping the range [bg_l, fg_l] to [0, 1], since
        // our final blend will be a linear interpolation from bg to fg.
        //
        // This yields virtually identical results for grayscale blending,
        // and very similar but non-identical results for color blending.
        float4 bg = in.bg_color;
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(bg.rgb);
        // To avoid numbers going haywire, we don't apply correction
        // when the bg and fg luminances are within 0.001 of each other.
        if (abs(fg_l - bg_l) > 0.001) {
          float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
          a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
      }

      // Multiply our whole color by the alpha mask.
      // Since we use premultiplied alpha, this is
      // the correct way to apply the mask.
      color *= a;

      return color;
    }

    case MODE_TEXT_COLOR: {
      // For now, we assume that color glyphs are
      // already premultiplied Display P3 colors.
      float4 color = textureColor.sample(textureSampler, in.tex_coord);

      // If we aren't doing linear blending, we can return this right away.
      if (!uniforms.use_linear_blending) {
        return color;
      }

      // Otherwise we need to linearize the color. Since the alpha is
      // premultiplied, we need to divide it out before linearizing.
      color.rgb /= color.a;
      color = linearize(color);
      color.rgb *= color.a;

      return color;
    }
  }
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
  texture2d<uint> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(address::clamp_to_edge, filter::linear);

  // Ehhhhh our texture is in RGBA8Uint but our color attachment is
  // BGRA8Unorm. So we need to convert it. We should really be converting
  // our texture to BGRA8Unorm.
  uint4 rgba = image.sample(textureSampler, in.tex_coord);

  return load_color(
    uchar4(rgba),
    // We assume all images are sRGB regardless of the configured colorspace
    // TODO: Maybe support wide gamut images?
    false,
    uniforms.use_linear_blending
  );
}

