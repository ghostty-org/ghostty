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
  float2 screen_size;
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
// Background Color Shader
//-------------------------------------------------------------------
#pragma mark - BG Color Shader

fragment float4 bg_color_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  return load_color(
    uniforms.bg_color,
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  );
}

//-------------------------------------------------------------------
// Background Image Shader
//-------------------------------------------------------------------
#pragma mark - BG Image Shader

struct BgImageVertexIn {
  float opacity [[attribute(0)]];
  uint8_t info [[attribute(1)]];
};

enum BgImagePosition : uint8_t {
  // 4 bits of info.
  BG_IMAGE_POSITION = 15u,

  BG_IMAGE_TL = 0u,
  BG_IMAGE_TC = 1u,
  BG_IMAGE_TR = 2u,
  BG_IMAGE_ML = 3u,
  BG_IMAGE_MC = 4u,
  BG_IMAGE_MR = 5u,
  BG_IMAGE_BL = 6u,
  BG_IMAGE_BC = 7u,
  BG_IMAGE_BR = 8u,
};

enum BgImageFit : uint8_t {
  // 2 bits of info shifted 4.
  BG_IMAGE_FIT = 3u << 4,

  BG_IMAGE_CONTAIN = 0u << 4,
  BG_IMAGE_COVER = 1u << 4,
  BG_IMAGE_STRETCH = 2u << 4,
  BG_IMAGE_NO_FIT = 3u << 4,
};

enum BgImageRepeat : uint8_t {
  // 1 bit of info shifted 6.
  BG_IMAGE_REPEAT = 1u << 6,
};

struct BgImageVertexOut {
  float4 position [[position]];
  float4 bg_color [[flat]];
  float2 offset [[flat]];
  float2 scale [[flat]];
  float opacity [[flat]];
  bool repeat [[flat]];
};

vertex BgImageVertexOut bg_image_vertex(
  uint vid [[vertex_id]],
  BgImageVertexIn in [[stage_in]],
  texture2d<float> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  BgImageVertexOut out;

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

  out.opacity = in.opacity;

  out.repeat = (in.info & BG_IMAGE_REPEAT) == BG_IMAGE_REPEAT;

  float2 screen_size = uniforms.screen_size;
  float2 tex_size = float2(image.get_width(), image.get_height());

  float2 dest_size = tex_size;
  switch (in.info & BG_IMAGE_FIT) {
    // For `contain` we scale by a factor that makes the image
    // width match the screen width or makes the image height
    // match the screen height, whichever is smaller.
    case BG_IMAGE_CONTAIN: {
      float scale = min(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
      dest_size = tex_size * scale;
    } break;

    // For `cover` we scale by a factor that makes the image
    // width match the screen width or makes the image height
    // match the screen height, whichever is larger.
    case BG_IMAGE_COVER: {
      float scale = max(screen_size.x / tex_size.x, screen_size.y / tex_size.y);
      dest_size = tex_size * scale;
    } break;

    // For `stretch` we stretch the image to the size of
    // the screen without worrying about aspect ratio.
    case BG_IMAGE_STRETCH: {
      dest_size = screen_size;
    } break;

    // For `none` we just use the original texture size.
    case BG_IMAGE_NO_FIT: {
      dest_size = tex_size;
    } break;
  }

  float2 start = float2(0.0);
  float2 mid = (screen_size - dest_size) / 2;
  float2 end = screen_size - dest_size;

  float2 dest_offset = mid;
  switch (in.info & BG_IMAGE_POSITION) {
    case BG_IMAGE_TL: {
      dest_offset = float2(start.x, start.y);
    } break;
    case BG_IMAGE_TC: {
      dest_offset = float2(mid.x, start.y);
    } break;
    case BG_IMAGE_TR: {
      dest_offset = float2(end.x, start.y);
    } break;
    case BG_IMAGE_ML: {
      dest_offset = float2(start.x, mid.y);
    } break;
    case BG_IMAGE_MC: {
      dest_offset = float2(mid.x, mid.y);
    } break;
    case BG_IMAGE_MR: {
      dest_offset = float2(end.x, mid.y);
    } break;
    case BG_IMAGE_BL: {
      dest_offset = float2(start.x, end.y);
    } break;
    case BG_IMAGE_BC: {
      dest_offset = float2(mid.x, end.y);
    } break;
    case BG_IMAGE_BR: {
      dest_offset = float2(end.x, end.y);
    } break;
  }

  out.offset = dest_offset;
  out.scale = tex_size / dest_size;

  // We load a fully opaque version of the bg color and combine it with
  // the alpha separately, because we need these as separate values in
  // the framgment shader.
  out.bg_color = float4(load_color(
    uchar4(uniforms.bg_color.rgb, 255),
    uniforms.use_display_p3,
    uniforms.use_linear_blending
  ).rgb, float(uniforms.bg_color.a) / 255.0);

  return out;
}

fragment float4 bg_image_fragment(
  BgImageVertexOut in [[stage_in]],
  texture2d<float> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_zero,
    filter::linear
  );

  // Our texture coordinate is based on the screen position, offset by the
  // dest rect origin, and scaled by the ratio between the dest rect size
  // and the original texture size, which effectively scales the original
  // size of the texture to the dest rect size.
  float2 tex_coord = (in.position.xy - in.offset) * in.scale;

  // If we need to repeat the texture, wrap the coordinates.
  if (in.repeat) {
    float2 tex_size = float2(image.get_width(), image.get_height());

    tex_coord = fmod(fmod(tex_coord, tex_size) + tex_size, tex_size);
  }

  float4 rgba = image.sample(textureSampler, tex_coord);

  if (!uniforms.use_linear_blending) {
    rgba = unlinearize(rgba);
  }

  // Premultiply the bg image.
  rgba.rgb *= rgba.a;

  // Multiply it by the configured opacity, but cap it at
  // the value that will make it fully opaque relative to
  // the background color alpha, so it isn't overexposed.
  rgba *= min(in.opacity, 1.0 / in.bg_color.a);

  // Blend it on to a fully opaque version of the background color.
  rgba += max(float4(0.0), float4(in.bg_color.rgb, 1.0) * (1.0 - rgba.a));

  // Multiply everything by the background color alpha.
  rgba *= in.bg_color.a;

  return rgba;
}

//-------------------------------------------------------------------
// Cell Background Shader
//-------------------------------------------------------------------
#pragma mark - Cell BG Shader

fragment float4 cell_bg_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]],
  constant uchar4 *cells [[buffer(2)]]
) {
  int2 grid_pos = int2(floor((in.position.xy - uniforms.grid_padding.wx) / uniforms.cell_size));

  float4 bg = float4(0.0);

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

  // Convert the color and return it.
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

enum CellTextAtlas : uint8_t {
  ATLAS_GRAYSCALE = 0u,
  ATLAS_COLOR = 1u,
};

// We use a packed struct of bools for misc properties of the glyph.
enum CellTextBools : uint8_t {
  // Don't apply min contrast to this glyph.
  NO_MIN_CONTRAST = 1u,
  // This is the cursor glyph.
  IS_CURSOR_GLYPH = 2u,
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

  // Which atlas to sample for our glyph.
  uint8_t atlas [[attribute(5)]];

  // Misc properties of the glyph.
  uint8_t bools [[attribute(6)]];
};

struct CellTextVertexOut {
  float4 position [[position]];
  uint8_t atlas [[flat]];
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
  float2 corner;
  corner.x = float(vid == 1 || vid == 3);
  corner.y = float(vid == 2 || vid == 3);

  CellTextVertexOut out;
  out.atlas = in.atlas;

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
  // Blend it with the global bg color
  float4 global_bg = load_color(
    uniforms.bg_color,
    uniforms.use_display_p3,
    true
  );
  out.bg_color += global_bg * (1.0 - out.bg_color.a);

  // If we have a minimum contrast, we need to check if we need to
  // change the color of the text to ensure it has enough contrast
  // with the background.
  if (uniforms.min_contrast > 1.0f && (in.bools & NO_MIN_CONTRAST) == 0) {
    // Ensure our minimum contrast
    out.color = contrasted_color(uniforms.min_contrast, out.color, out.bg_color);
  }

  // Check if current position is under cursor (including wide cursor)
  bool is_cursor_pos = (
      in.grid_pos.x == uniforms.cursor_pos.x ||
      uniforms.cursor_wide &&
        in.grid_pos.x == uniforms.cursor_pos.x + 1
    ) && in.grid_pos.y == uniforms.cursor_pos.y;

  // If this cell is the cursor cell, but we're not processing
  // the cursor glyph itself, then we need to change the color.
  if ((in.bools & IS_CURSOR_GLYPH) == 0 && is_cursor_pos) {
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
  constant Uniforms& uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_edge,
    filter::nearest
  );

  switch (in.atlas) {
    default:
    case ATLAS_GRAYSCALE: {
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

    case ATLAS_COLOR: {
      // For now, we assume that color glyphs
      // are already premultiplied linear colors.
      float4 color = textureColor.sample(textureSampler, in.tex_coord);

      // If we're doing linear blending, we can return this right away.
      if (uniforms.use_linear_blending) {
        return color;
      }

      // Otherwise we need to unlinearize the color. Since the alpha is
      // premultiplied, we need to divide it out before unlinearizing.
      color.rgb /= color.a;
      color = unlinearize(color);
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
  float2 corner;
  corner.x = float(vid == 1 || vid == 3);
  corner.y = float(vid == 2 || vid == 3);

  // The texture coordinates start at our source x/y
  // and add the width/height depending on the corner.
  //
  // We don't need to normalize because we use pixel addressing for our sampler.
  float2 tex_coord = in.source_rect.xy;
  tex_coord += in.source_rect.zw * corner;

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
  texture2d<float> image [[texture(0)]],
  constant Uniforms& uniforms [[buffer(1)]]
) {
  constexpr sampler textureSampler(
    coord::pixel,
    address::clamp_to_edge,
    filter::linear
  );

  float4 rgba = image.sample(textureSampler, in.tex_coord);

  if (!uniforms.use_linear_blending) {
    rgba = unlinearize(rgba);
  }

  rgba.rgb *= rgba.a;

  return rgba;
}

