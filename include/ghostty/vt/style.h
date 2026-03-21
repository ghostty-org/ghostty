/**
 * @file style.h
 *
 * Terminal cell style types.
 */

#ifndef GHOSTTY_VT_STYLE_H
#define GHOSTTY_VT_STYLE_H

#include <ghostty/vt/color.h>
#include <ghostty/vt/types.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup style Style
 *
 * Terminal cell style attributes.
 *
 * A style describes the visual attributes of a terminal cell, including
 * foreground, background, and underline colors, as well as flags for
 * bold, italic, underline, and other text decorations.
 *
 * @{
 */

/**
 * Style identifier type.
 *
 * Used to look up the full style from a grid reference.
 * Obtain this from a cell via GHOSTTY_CELL_DATA_STYLE_ID.
 *
 * @ingroup style
 */
typedef uint16_t GhosttyStyleId;

/**
 * Style color tags.
 *
 * These values identify the type of color in a style color.
 * Use the tag to determine which field in the color value union to access.
 *
 * @ingroup style
 */
typedef enum {
  GHOSTTY_STYLE_COLOR_NONE = 0,
  GHOSTTY_STYLE_COLOR_PALETTE = 1,
  GHOSTTY_STYLE_COLOR_RGB = 2,
} GhosttyStyleColorTag;

/**
 * Style color value union.
 *
 * Use the tag to determine which field is active.
 *
 * @ingroup style
 */
typedef union {
  GhosttyColorPaletteIndex palette;
  GhosttyColorRgb rgb;
  uint64_t _padding;
} GhosttyStyleColorValue;

/**
 * Style color (tagged union).
 *
 * A color used in a style attribute. Can be unset (none), a palette
 * index, or a direct RGB value.
 *
 * @ingroup style
 */
typedef struct {
  GhosttyStyleColorTag tag;
  GhosttyStyleColorValue value;
} GhosttyStyleColor;

/**
 * Terminal cell style.
 *
 * Describes the complete visual style for a terminal cell, including
 * foreground, background, and underline colors, as well as text
 * decoration flags. The underline field uses the same values as
 * GhosttySgrUnderline.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 *
 * @ingroup style
 */
typedef struct {
  size_t size;
  GhosttyStyleColor fg_color;
  GhosttyStyleColor bg_color;
  GhosttyStyleColor underline_color;
  bool bold;
  bool italic;
  bool faint;
  bool blink;
  bool inverse;
  bool invisible;
  bool strikethrough;
  bool overline;
  int underline; /**< One of GHOSTTY_SGR_UNDERLINE_* values */
} GhosttyStyle;

/**
 * Get the default style.
 *
 * Initializes the style to the default values (no colors, no flags).
 *
 * @param style Pointer to the style to initialize
 *
 * @ingroup style
 */
void ghostty_style_default(GhosttyStyle* style);

/**
 * Check if a style is the default style.
 *
 * Returns true if all colors are unset and all flags are off.
 *
 * @param style Pointer to the style to check
 * @return true if the style is the default style
 *
 * @ingroup style
 */
bool ghostty_style_is_default(const GhosttyStyle* style);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_STYLE_H */
