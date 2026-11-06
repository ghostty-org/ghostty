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

/** @addtogroup style
 *
 * A GhosttyStyle is how a cell looks: its foreground, background, and underline
 * colors, and flags for bold, italic, underline, and other text decorations.
 *
 * You get one from ghostty_grid_ref_style(), or from a render state when you
 * draw. Its colors can be unset, which means you use your default.
 *
 * ## Example
 *
 * @code{.c}
 * GhosttyStyle style;
 * ghostty_grid_ref_style(&ref, &style);
 * bool bold = style.flags & GHOSTTY_STYLE_FLAG_BOLD;
 * @endcode
 *
 * Full program: @ref c-vt-grid-traverse/src/main.c
 *
 * See the @ref guide-grid "Grid guide".
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
 * Identifies which kind of color a GhosttyStyleColor holds. The tag is
 * stored in the one-byte `tag` field of GhosttyStyleColor, so compare
 * that field against these values.
 *
 * @ingroup style
 */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_STYLE_COLOR_NONE = 0,
  GHOSTTY_STYLE_COLOR_PALETTE = 1,
  GHOSTTY_STYLE_COLOR_RGB = 2,
  GHOSTTY_STYLE_COLOR_TAG_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
  } GhosttyStyleColorTag;

/**
 * Style color value.
 *
 * The color data of a GhosttyStyleColor, three bytes long. The tag of
 * the containing color says which field to read:
 *
 * - GHOSTTY_STYLE_COLOR_NONE: no field is set and all bytes are zero.
 * - GHOSTTY_STYLE_COLOR_PALETTE: read `palette`. The remaining two
 *   bytes are zero.
 * - GHOSTTY_STYLE_COLOR_RGB: read `rgb`.
 *
 * @ingroup style
 */
typedef union {
  GhosttyColorPaletteIndex palette;
  GhosttyColorRgb rgb;
} GhosttyStyleColorValue;

/**
 * Style color.
 *
 * A color used by a style. It is either unset, an index into the
 * terminal palette, or a direct RGB value. The struct is four bytes: a
 * one-byte tag followed by the three-byte value.
 *
 * An unset color means the style does not choose a color. Use the
 * terminal's default color for that slot instead.
 *
 * @code{.c}
 * switch (style.fg_color.tag) {
 *   case GHOSTTY_STYLE_COLOR_NONE:
 *     // Use the terminal's default foreground color.
 *     break;
 *   case GHOSTTY_STYLE_COLOR_PALETTE:
 *     // Look up style.fg_color.value.palette in the palette.
 *     break;
 *   case GHOSTTY_STYLE_COLOR_RGB:
 *     // Use style.fg_color.value.rgb directly.
 *     break;
 * }
 * @endcode
 *
 * @ingroup style
 */
typedef struct {
  /** The kind of color. One of the GhosttyStyleColorTag values. */
  uint8_t tag;

  /** The color data. Which field is valid depends on `tag`. */
  GhosttyStyleColorValue value;
} GhosttyStyleColor;

/**
 * Style flags.
 *
 * A 16-bit set of text attributes, laid out as follows:
 *
 * | Bits     | Meaning                                             |
 * |----------|-----------------------------------------------------|
 * | 0 to 7   | On/off attributes, one GHOSTTY_STYLE_FLAG_* per bit |
 * | 8 to 10  | Underline style, a GhosttySgrUnderline value        |
 * | 11 to 15 | Reserved, always zero                               |
 *
 * Test an attribute with a bitwise AND against its GHOSTTY_STYLE_FLAG_*
 * mask. Read the underline style with GHOSTTY_STYLE_UNDERLINE().
 *
 * @ingroup style
 */
typedef uint16_t GhosttyStyleFlags;

/** Bold text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_BOLD ((GhosttyStyleFlags)(1u << 0))
/** Italic text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_ITALIC ((GhosttyStyleFlags)(1u << 1))
/** Faint (dim) text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_FAINT ((GhosttyStyleFlags)(1u << 2))
/** Blinking text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_BLINK ((GhosttyStyleFlags)(1u << 3))
/** Inverse text, with the foreground and background swapped. @ingroup style */
#define GHOSTTY_STYLE_FLAG_INVERSE ((GhosttyStyleFlags)(1u << 4))
/** Invisible (hidden) text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_INVISIBLE ((GhosttyStyleFlags)(1u << 5))
/** Strikethrough text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_STRIKETHROUGH ((GhosttyStyleFlags)(1u << 6))
/** Overlined text. @ingroup style */
#define GHOSTTY_STYLE_FLAG_OVERLINE ((GhosttyStyleFlags)(1u << 7))

/**
 * The lowest bit of the underline style in GhosttyStyleFlags.
 *
 * @ingroup style
 */
#define GHOSTTY_STYLE_UNDERLINE_SHIFT 8

/**
 * The bits of GhosttyStyleFlags that hold the underline style.
 *
 * @ingroup style
 */
#define GHOSTTY_STYLE_UNDERLINE_MASK \
  ((GhosttyStyleFlags)(0x7u << GHOSTTY_STYLE_UNDERLINE_SHIFT))

/**
 * Get the underline style of a GhosttyStyle.
 *
 * The result is a GhosttySgrUnderline value. GHOSTTY_SGR_UNDERLINE_NONE
 * (zero) means the text is not underlined, so the result can also be
 * used as a true/false check.
 *
 * @code{.c}
 * switch (GHOSTTY_STYLE_UNDERLINE(style)) {
 *   case GHOSTTY_SGR_UNDERLINE_NONE: break;
 *   case GHOSTTY_SGR_UNDERLINE_CURLY: draw_curly_underline(); break;
 *   default: draw_straight_underline(); break;
 * }
 * @endcode
 *
 * @param style A GhosttyStyle value, not a pointer to one
 * @return The underline style as an int
 *
 * @ingroup style
 */
#define GHOSTTY_STYLE_UNDERLINE(style) \
  ((int)(((style).flags & GHOSTTY_STYLE_UNDERLINE_MASK) >> \
         GHOSTTY_STYLE_UNDERLINE_SHIFT))

/**
 * Terminal cell style.
 *
 * The complete visual style of a terminal cell: foreground, background,
 * and underline colors, plus text attributes such as bold and the
 * underline style.
 *
 * The layout of this struct is fixed. It is 16 bytes on every platform
 * and will not change in future versions, so it does not have a size
 * field and does not need GHOSTTY_INIT_SIZED(). If a future version
 * needs more style attributes, it will add a new type instead of
 * changing this one.
 *
 * Reserved bits are always zero in a style written by the library.
 * This means two styles from the library can be compared with memcmp().
 *
 * @code{.c}
 * GhosttyStyle style;
 * ghostty_render_state_row_cells_get(
 *     cells, GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
 *
 * if (style.flags & GHOSTTY_STYLE_FLAG_BOLD) {
 *   // Draw with a bold font.
 * }
 *
 * if (GHOSTTY_STYLE_UNDERLINE(style) != GHOSTTY_SGR_UNDERLINE_NONE) {
 *   // Draw an underline, colored by style.underline_color if it is set.
 * }
 * @endcode
 *
 * @ingroup style
 */
typedef struct {
  /** Foreground (text) color. */
  GhosttyStyleColor fg_color;

  /** Background color. */
  GhosttyStyleColor bg_color;

  /** Underline color. */
  GhosttyStyleColor underline_color;

  /** Text attributes and underline style. See GhosttyStyleFlags. */
  GhosttyStyleFlags flags;

  /** Reserved for future use. Always zero. */
  uint16_t reserved;
} GhosttyStyle;

/**
 * Get the default style.
 *
 * Initializes the style to the default values (no colors, no flags).
 * The default style is all zero bytes.
 *
 * @param style Pointer to the style to initialize
 *
 * @ingroup style
 */
GHOSTTY_API void ghostty_style_default(GhosttyStyle* style);

/**
 * Check if a style is the default style.
 *
 * Returns true if all colors are unset and all flags are off. Reserved
 * bits are ignored.
 *
 * @param style Pointer to the style to check
 * @return true if the style is the default style
 *
 * @ingroup style
 */
GHOSTTY_API bool ghostty_style_is_default(const GhosttyStyle* style);

#ifdef __cplusplus
}
#endif

/** @} */

#endif /* GHOSTTY_VT_STYLE_H */
