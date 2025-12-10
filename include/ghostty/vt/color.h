/**
 * @file color.h
 *
 * Color types and utilities.
 */

#ifndef GHOSTTY_VT_COLOR_H
#define GHOSTTY_VT_COLOR_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * RGB color value.
 *
 * @ingroup sgr
 */
typedef struct {
  uint8_t r; /**< Red component (0-255) */
  uint8_t g; /**< Green component (0-255) */
  uint8_t b; /**< Blue component (0-255) */
} GhosttyColorRgb;

/**
 * Palette color index (0-255).
 *
 * @ingroup sgr
 */
typedef uint8_t GhosttyColorPaletteIndex;

/** @addtogroup sgr
 * @{
 */

/** Black color (0) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BLACK 0
/** Red color (1) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_RED 1
/** Green color (2) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_GREEN 2
/** Yellow color (3) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_YELLOW 3
/** Blue color (4) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BLUE 4
/** Magenta color (5) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_MAGENTA 5
/** Cyan color (6) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_CYAN 6
/** White color (7) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_WHITE 7
/** Bright black color (8) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_BLACK 8
/** Bright red color (9) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_RED 9
/** Bright green color (10) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_GREEN 10
/** Bright yellow color (11) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_YELLOW 11
/** Bright blue color (12) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_BLUE 12
/** Bright magenta color (13) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_MAGENTA 13
/** Bright cyan color (14) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_CYAN 14
/** Bright white color (15) @ingroup sgr */
#define GHOSTTY_COLOR_NAMED_BRIGHT_WHITE 15

/** @} */

/**
 * Get the RGB color components.
 *
 * This function extracts the individual red, green, and blue components
 * from a GhosttyColorRgb value. Primarily useful in WebAssembly environments
 * where accessing struct fields directly is difficult.
 *
 * @param color The RGB color value
 * @param r Pointer to store the red component (0-255)
 * @param g Pointer to store the green component (0-255)
 * @param b Pointer to store the blue component (0-255)
 *
 * @ingroup sgr
 */
void ghostty_color_rgb_get(GhosttyColorRgb color,
                           uint8_t* r,
                           uint8_t* g,
                           uint8_t* b);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_COLOR_H */
