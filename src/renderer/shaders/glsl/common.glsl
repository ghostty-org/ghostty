#version 430 core

// These are common definitions to be shared across shaders, the first
// line of any shader that needs these should be `#include "common.glsl"`.
//
// Included in this file are:
// - The interface block for the global uniforms.
// - Functions for unpacking values.
// - Functions for working with colors.

//----------------------------------------------------------------------------//
// Global Uniforms
//----------------------------------------------------------------------------//
layout(binding = 1, std140) uniform Globals {
    uniform mat4 projection_matrix;
    uniform vec2 screen_size;
    uniform vec2 cell_size;
    uniform uint grid_size_packed_2u16;
    uniform vec4 grid_padding;
    // Smooth scrolling: .x = sub-row viewport offset in pixels (positive:
    // content shifted down), .y = grid rows above the viewport, .z = the
    // height the viewport's rows don't account for, which the shifted grid
    // may draw into (it is surface, not padding). Grid row y is drawn at
    // (y - .y) * cell_size.y + .x.
    uniform vec4 scroll_offset;
    uniform uint padding_extend;
    uniform float min_contrast;
    uniform uint cursor_pos_packed_2u16;
    uniform uint cursor_color_packed_4u8;
    uniform uint bg_color_packed_4u8;
    uniform uint bools;
    // Region scroll animation; see the Metal Uniforms for the meaning.
    // region_rect[i]: animating rectangle in grid pixels (left, top,
    // right, bottom); region_shift[i].x: how far its content is drawn
    // from its final place (positive: down). Grid row grid_size.y + k is
    // a ghost row from region ghost_rows[k].x drawn at row ghost_rows[k].y.
    // anim_counts.x regions and .y ghost rows are live.
    uniform vec4 region_rect[4];
    uniform vec4 region_shift[4];
    uniform ivec4 ghost_rows[64];
    uniform uvec4 anim_counts;
    // Smooth cursor: the rectangle the focused cursor fills, in grid
    // pixels (left, top, width, height), filled with cursor_fill by the
    // background shader; all zero while no cursor is drawn this way.
    uniform vec4 cursor_rect;
    uniform uint cursor_fill_packed_4u8;
    // Cursor trail: the streak's segment as the centers it is swept
    // between in grid pixels (from.xy, to.xy), and its half size (.xy)
    // and opacity (.z); opacity 0 while there is none.
    uniform vec4 cursor_trail;
    uniform vec4 cursor_trail_size;
};

// Cursor trail: the streak's opacity at grid pixel p. An axis-aligned box
// of the trail's half size swept along its segment (it slides rather than
// rotates, so a diagonal move leaves a slanted streak with square ends),
// with a one-pixel antialiased edge, times the streak's opacity.
float trail_coverage(vec2 p) {
    vec4 s = cursor_trail_size;
    if (s.z <= 0.0) return 0.0;
    vec2 a = cursor_trail.xy;
    vec2 b = cursor_trail.zw;
    vec2 ab = b - a;
    float h = clamp(dot(p - a, ab) / max(dot(ab, ab), 1e-6), 0.0, 1.0);
    vec2 d = abs(p - (a + ab * h)) - s.xy;
    float dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
    return (1.0 - smoothstep(0.0, 1.0, dist)) * s.z;
}

// Smooth cursor: how much of the 1x1 pixel centered on grid pixel p lies
// inside cursor_rect. Exact box coverage, so a resting cursor on whole
// pixels is as hard-edged as the sprite it replaces and only an edge in
// motion blends.
float cursor_coverage(vec2 p) {
    vec4 r = cursor_rect;
    if (r.z <= 0.0 || r.w <= 0.0) return 0.0;
    vec2 lo = r.xy;
    vec2 hi = r.xy + r.zw;
    vec2 c = clamp(min(hi, p + 0.5) - max(lo, p - 0.5), 0.0, 1.0);
    return c.x * c.y;
}

// A drawn position back on the grid's pixels: minus the padding and the
// smooth-scroll shift. A region scroll's shift stays in, as it is in
// cursor_rect.
vec2 grid_pixel(vec2 position) {
    float shift_y = scroll_offset.x - scroll_offset.y * cell_size.y;
    return position - grid_padding.wx - vec2(0.0, shift_y);
}

// The region scroll animation a grid cell takes part in, or -1. `pos` is
// the cell's top-left in grid pixels, before any shift.
int region_of(vec2 pos) {
    for (uint i = 0u; i < anim_counts.x; i++) {
        vec4 r = region_rect[i];
        if (pos.x >= r.x && pos.x < r.z && pos.y >= r.y && pos.y < r.w) {
            return int(i);
        }
    }
    return -1;
}

// Bools
const uint CURSOR_WIDE = 1u;
const uint USE_DISPLAY_P3 = 2u;
const uint USE_LINEAR_BLENDING = 4u;
const uint USE_LINEAR_CORRECTION = 8u;
// Smooth cursor: color text as cursor text by cursor_rect's coverage (a
// block cursor), in place of the whole-cell recolor under cursor_pos.
const uint CURSOR_GLIDE_TEXT = 16u;

// Padding extend enum
const uint EXTEND_LEFT = 1u;
const uint EXTEND_RIGHT = 2u;
const uint EXTEND_UP = 4u;
const uint EXTEND_DOWN = 8u;

//----------------------------------------------------------------------------//
// Functions for Unpacking Values
//----------------------------------------------------------------------------//
// NOTE: These unpack functions assume little-endian.
//       If this ever becomes a problem... oh dear!

uvec4 unpack4u8(uint packed_value) {
    return uvec4(
        uint(packed_value >> 0) & uint(0xFF),
        uint(packed_value >> 8) & uint(0xFF),
        uint(packed_value >> 16) & uint(0xFF),
        uint(packed_value >> 24) & uint(0xFF)
    );
}

uvec2 unpack2u16(uint packed_value) {
    return uvec2(
        uint(packed_value >> 0) & uint(0xFFFF),
        uint(packed_value >> 16) & uint(0xFFFF)
    );
}

ivec2 unpack2i16(int packed_value) {
    return ivec2(
        (packed_value << 16) >> 16,
        (packed_value << 0) >> 16
    );
}

//----------------------------------------------------------------------------//
// Color Functions
//----------------------------------------------------------------------------//

// Compute the luminance of the provided color.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float luminance(vec3 color) {
    return dot(color, vec3(0.2126f, 0.7152f, 0.0722f));
}

// https://www.w3.org/TR/2008/REC-WCAG20-20081211/#contrast-ratiodef
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
float contrast_ratio(vec3 color1, vec3 color2) {
    float luminance1 = luminance(color1) + 0.05;
    float luminance2 = luminance(color2) + 0.05;
    return max(luminance1, luminance2) / min(luminance1, luminance2);
}

// Return the fg if the contrast ratio is greater than min, otherwise
// return a color that satisfies the contrast ratio. Currently, the color
// is always white or black, whichever has the highest contrast ratio.
//
// Takes colors in linear RGB space. If your colors are gamma
// encoded, linearize them before using them with this function.
vec4 contrasted_color(float min_ratio, vec4 fg, vec4 bg) {
    float ratio = contrast_ratio(fg.rgb, bg.rgb);
    if (ratio < min_ratio) {
        float white_ratio = contrast_ratio(vec3(1.0, 1.0, 1.0), bg.rgb);
        float black_ratio = contrast_ratio(vec3(0.0, 0.0, 0.0), bg.rgb);
        if (white_ratio > black_ratio) {
            return vec4(1.0);
        } else {
            return vec4(0.0, 0.0, 0.0, 1.0);
        }
    }

    return fg;
}

// Converts a color from sRGB gamma encoding to linear.
vec4 linearize(vec4 srgb) {
    bvec3 cutoff = lessThanEqual(srgb.rgb, vec3(0.04045));
    vec3 higher = pow((srgb.rgb + vec3(0.055)) / vec3(1.055), vec3(2.4));
    vec3 lower = srgb.rgb / vec3(12.92);

    return vec4(mix(higher, lower, cutoff), srgb.a);
}
float linearize(float v) {
    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4);
}

// Converts a color from linear to sRGB gamma encoding.
vec4 unlinearize(vec4 linear) {
    bvec3 cutoff = lessThanEqual(linear.rgb, vec3(0.0031308));
    vec3 higher = pow(linear.rgb, vec3(1.0 / 2.4)) * vec3(1.055) - vec3(0.055);
    vec3 lower = linear.rgb * vec3(12.92);

    return vec4(mix(higher, lower, cutoff), linear.a);
}
float unlinearize(float v) {
    return v <= 0.0031308 ? v * 12.92 : pow(v, 1.0 / 2.4) * 1.055 - 0.055;
}

// Load a 4 byte RGBA non-premultiplied color and linearize
// and convert it as necessary depending on the provided info.
//
// `linear` controls whether the returned color is linear or gamma encoded.
vec4 load_color(
    uvec4 in_color,
    bool linear
) {
    // 0 .. 255 -> 0.0 .. 1.0
    vec4 color = vec4(in_color) / vec4(255.0f);

    // Linearize if necessary.
    if (linear) color = linearize(color);

    // Premultiply our color by its alpha.
    color.rgb *= color.a;

    return color;
}

//----------------------------------------------------------------------------//
