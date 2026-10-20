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
  // Smooth scrolling: .x = sub-row viewport offset in pixels (positive:
  // content shifted down), .y = grid rows above the viewport, .z = the
  // height the viewport's rows don't account for, which the shifted grid
  // may draw into (it is surface, not padding). Grid row y is drawn at
  // (y - .y) * cell_size.y + .x.
  float4 scroll_offset;
  uint8_t padding_extend;
  float min_contrast;
  ushort2 cursor_pos;
  uchar4 cursor_color;
  uchar4 bg_color;
  bool cursor_wide;
  bool use_display_p3;
  bool use_linear_blending;
  bool use_linear_correction;
  // Smooth cursor: color text as cursor text by how much of each pixel
  // cursor_rect covers (a block cursor), in place of the whole-cell
  // recolor under cursor_pos, which is then unset.
  bool cursor_glide_text;
  // Region scroll animation. region_rect[i] is an animating rectangle in
  // grid pixels (left, top, right, bottom); region_shift[i].x is how far
  // its content is currently drawn from its final place (positive: down).
  // Grid row grid_size.y + k is a ghost row that scrolled out of region
  // ghost_rows[k].x and is drawn at row ghost_rows[k].y, outside the
  // region, clipped to it. anim_counts.x regions and .y ghosts are live.
  float4 region_rect[4];
  float4 region_shift[4];
  int4 ghost_rows[64];
  uint4 anim_counts;
  // Smooth cursor: the rectangle the focused cursor fills, in grid pixels
  // (left, top, width, height), filled with cursor_fill by the background
  // shader; all zero while no cursor is drawn this way.
  float4 cursor_rect;
  uchar4 cursor_fill;
  // Cursor trail: the streak's segment as the centers it is swept between
  // in grid pixels (from.xy, to.xy), and its half size (.xy) and opacity
  // (.z); opacity 0 while there is none. Drawn in cursor_fill's color.
  float4 cursor_trail;
  float4 cursor_trail_size;
};

// Cursor trail: the streak's opacity at grid pixel p. An axis-aligned box
// of the trail's half size swept along its segment (it slides rather than
// rotates, so a diagonal move leaves a slanted streak with square ends),
// with a one-pixel antialiased edge, times the streak's opacity.
float trail_coverage(constant Uniforms& uniforms, float2 p) {
  float4 s = uniforms.cursor_trail_size;
  if (s.z <= 0.0) return 0.0;
  float2 a = uniforms.cursor_trail.xy;
  float2 b = uniforms.cursor_trail.zw;
  float2 ab = b - a;
  float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
  float2 d = abs(p - (a + ab * h)) - s.xy;
  float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
  return (1.0 - smoothstep(0.0, 1.0, dist)) * s.z;
}

// Smooth cursor: how much of the 1x1 pixel centered on grid pixel p lies
// inside cursor_rect. Exact box coverage, so a resting cursor on whole
// pixels is as hard-edged as the sprite it replaces and only an edge in
// motion blends.
float cursor_coverage(constant Uniforms& uniforms, float2 p) {
  float4 r = uniforms.cursor_rect;
  if (r.z <= 0.0 || r.w <= 0.0) return 0.0;
  float2 lo = r.xy;
  float2 hi = r.xy + r.zw;
  float2 c = clamp(min(hi, p + 0.5) - max(lo, p - 0.5), 0.0, 1.0);
  return c.x * c.y;
}

// A drawn position back on the grid's pixels: minus the padding and the
// smooth-scroll shift. A region scroll's shift stays in, as it is in
// cursor_rect.
float2 grid_pixel(constant Uniforms& uniforms, float2 position) {
  float shift_y = uniforms.scroll_offset.x -
      uniforms.scroll_offset.y * uniforms.cell_size.y;
  return position - uniforms.grid_padding.wx - float2(0.0, shift_y);
}

// The region scroll animation a grid cell takes part in, or -1. `pos` is
// the cell's top-left in grid pixels, before any shift.
int region_of(constant Uniforms& uniforms, float2 pos) {
  for (uint i = 0; i < uniforms.anim_counts.x; i++) {
    float4 r = uniforms.region_rect[i];
    if (pos.x >= r.x && pos.x < r.z && pos.y >= r.y && pos.y < r.w) {
      return int(i);
    }
  }
  return -1;
}

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

// The cell background under a fragment: the cell's own color, a region
// scroll's shifted or ghost row, or the padding's extension of an edge.
// `rel` is the fragment relative to the grid and `visible` the grid's
// extent, both from cell_bg_fragment.
float4 cell_bg_base(
  constant Uniforms& uniforms,
  constant uchar4 *cells,
  float2 rel,
  float2 visible
) {
  // Position relative to the visible grid. Its extent comes from the
  // grid itself, not from grid_padding's bottom/right, which hold the
  // leftover measured at the last resize and can be stale. While smooth
  // scrolling the grid carries one row more than is visible. Padding
  // decisions use this unshifted position; the cell lookup below then
  // applies the shift, so a partially revealed row never leaks into
  // the padding.
  float4 bg = float4(0.0);

  // Clamp x position, extends edge bg colors in to padding on sides.
  if (rel.x < 0.0) {
    if (uniforms.padding_extend & EXTEND_LEFT) {
      rel.x = 0.0;
    } else {
      return bg;
    }
  } else if (rel.x >= visible.x) {
    if (uniforms.padding_extend & EXTEND_RIGHT) {
      rel.x = visible.x - 0.5;
    } else {
      return bg;
    }
  }

  // Clamp y position if we should extend, otherwise discard if out of bounds.
  if (rel.y < 0.0) {
    if (uniforms.padding_extend & EXTEND_UP) {
      rel.y = 0.0;
    } else {
      return bg;
    }
  } else if (rel.y >= visible.y) {
    if (uniforms.padding_extend & EXTEND_DOWN) {
      rel.y = visible.y - 0.5;
    } else {
      return bg;
    }
  }

  float shift_y = uniforms.scroll_offset.x -
      uniforms.scroll_offset.y * uniforms.cell_size.y;
  float2 grid_px = rel - float2(0.0, shift_y);

  // Region scroll animation: inside an animating rectangle the content
  // is drawn shifted, so look the cell up where it is drawn from. Past
  // the region's own rows that is a ghost row sliding out, if one is
  // still there, and otherwise nothing: the surface background.
  int region = region_of(uniforms, grid_px);
  if (region >= 0) {
    float4 r = uniforms.region_rect[region];
    float y = grid_px.y - uniforms.region_shift[region].x;
    int row = int(floor(y / uniforms.cell_size.y));
    int col = clamp(int(floor(grid_px.x / uniforms.cell_size.x)),
                    0, int(uniforms.grid_size.x) - 1);
    int cols = int(uniforms.grid_size.x);
    if (y >= r.y && y < r.w) {
      row = clamp(row, 0, int(uniforms.grid_size.y) - 1);
      return load_color(cells[row * cols + col],
                        uniforms.use_display_p3,
                        uniforms.use_linear_blending);
    }
    for (uint k = 0; k < uniforms.anim_counts.y; k++) {
      int4 ghost = uniforms.ghost_rows[k];
      if (ghost.x == region && ghost.y == row) {
        return load_color(cells[(int(uniforms.grid_size.y) + int(k)) * cols + col],
                          uniforms.use_display_p3,
                          uniforms.use_linear_blending);
      }
    }
    return bg;
  }

  int2 grid_pos = int2(floor(grid_px / uniforms.cell_size));
  grid_pos = clamp(grid_pos, int2(0), int2(uniforms.grid_size) - 1);

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

fragment float4 cell_bg_fragment(
  FullScreenVertexOut in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]],
  constant uchar4 *cells [[buffer(2)]]
) {
  float2 rel = in.position.xy - uniforms.grid_padding.wx;
  float extra_rows = uniforms.scroll_offset.x != 0.0
      ? max(uniforms.scroll_offset.y + uniforms.scroll_offset.w, 1.0)
      : 0.0;
  float2 visible = uniforms.cell_size *
      float2(uniforms.grid_size.x, float(uniforms.grid_size.y) - extra_rows);
  // A shifted grid sits on the height its rows don't account for, so that
  // strip is grid, not padding.
  visible.y += uniforms.scroll_offset.x != 0.0 ? uniforms.scroll_offset.z : 0.0;

  float4 bg = cell_bg_base(uniforms, cells, rel, visible);

  // Cursor trail and smooth cursor: the streak behind the cursor, then
  // the cursor filling its rect over it, both over the cell background
  // and under the text, each as far as it covers the pixel. Only inside
  // the visible grid, so neither paints the padding while riding a scroll.
  if (all(rel >= 0.0) && all(rel < visible)) {
    float2 p = grid_pixel(uniforms, in.position.xy);
    float trail = trail_coverage(uniforms, p);
    if (trail > 0.0) {
      float4 streak = load_color(
        uchar4(uniforms.cursor_fill.rgb, 255),
        uniforms.use_display_p3,
        uniforms.use_linear_blending
      );
      bg = bg * (1.0 - trail) + streak * trail;
    }
    float cov = cursor_coverage(uniforms, p);
    if (cov > 0.0) {
      float4 fill = load_color(
        uniforms.cursor_fill,
        uniforms.use_display_p3,
        uniforms.use_linear_blending
      );
      bg = bg * (1.0 - fill.a * cov) + fill * cov;
    }
  }

  return bg;
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
  // Grid-pixel rectangle the glyph is clipped to: the region it is
  // scrolling in, or everything.
  float4 clip [[flat]];
};

vertex CellTextVertexOut cell_text_vertex(
  uint vid [[vertex_id]],
  CellTextVertexIn in [[stage_in]],
  constant Uniforms& uniforms [[buffer(1)]],
  constant uchar4 *bg_colors [[buffer(2)]]
) {
  // Convert the grid x, y into world space x, y by accounting for cell size
  float2 cell_pos = uniforms.cell_size * float2(in.grid_pos);

  // Region scroll animation: a ghost row (beyond the grid) is drawn at
  // the row it scrolled to, and every cell of an animating region is
  // shifted by the region's remaining distance and clipped to it.
  float4 clip = float4(-1.0e9, -1.0e9, 1.0e9, 1.0e9);
  int region = -1;
  if (in.grid_pos.y >= uniforms.grid_size.y) {
    int4 ghost = uniforms.ghost_rows[in.grid_pos.y - uniforms.grid_size.y];
    region = ghost.x;
    cell_pos.y = uniforms.cell_size.y * float(ghost.y);
  } else {
    region = region_of(uniforms, cell_pos);
  }
  if (region >= 0) {
    cell_pos.y += uniforms.region_shift[region].x;
    clip = uniforms.region_rect[region];
  }

  // Smooth scrolling: grid rows are shifted by the sub-row offset, with
  // an extra row above the viewport drawn at negative y.
  cell_pos.y += uniforms.scroll_offset.x -
      uniforms.scroll_offset.y * uniforms.cell_size.y;

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
  out.clip = clip;

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
      true
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

  // Region scroll animation: a glyph sliding in or out of its region
  // stops at the region's edge.
  {
    float2 rel = in.position.xy - uniforms.grid_padding.wx;
    if (rel.x < in.clip.x || rel.x >= in.clip.z ||
        rel.y < in.clip.y || rel.y >= in.clip.w) {
      discard_fragment();
    }
  }

  // Smooth scrolling: a partially revealed row extends into the padding;
  // clip it to the visible grid. Only while shifted, so glyphs that
  // legitimately overhang a cell edge are untouched at rest.
  if (uniforms.scroll_offset.x != 0.0) {
    float y = in.position.y - uniforms.grid_padding.x;
    float extra_rows = max(uniforms.scroll_offset.y + uniforms.scroll_offset.w, 1.0);
    float visible_h =
        (float(uniforms.grid_size.y) - extra_rows) * uniforms.cell_size.y +
        uniforms.scroll_offset.z;
    if (y < 0.0 || y >= visible_h) discard_fragment();
  }

  switch (in.atlas) {
    default:
    case ATLAS_GRAYSCALE: {
      // Our input color is always linear.
      float4 color = in.color;

      // Smooth cursor: a block cursor colors the glyph as cursor text by
      // how much of this pixel it covers, so a glyph it is halfway across
      // is two-toned. The invisible cursor sprite (alpha 0) stays so.
      if (uniforms.cursor_glide_text && color.a > 0.0) {
        float cov = cursor_coverage(uniforms, grid_pixel(uniforms, in.position.xy));
        if (cov > 0.0) {
          float4 cursor_text = load_color(
            uniforms.cursor_color,
            uniforms.use_display_p3,
            true
          );
          color = mix(color, cursor_text, cov);
        }
      }

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

  // Smooth scrolling: image placements are in terminal viewport rows,
  // so they move by the sub-row offset alone.
  image_pos.y += uniforms.scroll_offset.x;

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

