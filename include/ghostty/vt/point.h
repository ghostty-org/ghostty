/**
 * @file point.h
 *
 * Terminal point types for referencing locations in the terminal grid.
 */

#ifndef GHOSTTY_VT_POINT_H
#define GHOSTTY_VT_POINT_H

#include <stdint.h>

#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @addtogroup point
 *
 * A GhosttyPoint names a position in the terminal grid, in one of four
 * coordinate systems: the active area, the viewport, the full screen, or the
 * scrollback history.
 *
 * You need one to find a cell. The same row has a different number in each
 * system, so pick the one that matches what you're asking. Resolve a point to
 * a cell with ghostty_terminal_grid_ref().
 *
 * ## Example
 *
 * @code{.c}
 * GhosttyPoint point = {
 *     .tag = GHOSTTY_POINT_TAG_VIEWPORT,
 *     .value = { .coordinate = { .x = 4, .y = 0 } },
 * };
 * @endcode
 *
 * Full program: @ref c-vt-grid-traverse/src/main.c
 *
 * The @ref guide-grid "Grid guide" shows how they line up.
 *
 * @{
 */

/**
 * A coordinate in the terminal grid.
 *
 * @ingroup point
 */
typedef struct {
  /** Column (0-indexed). */
  uint16_t x;

  /** Row (0-indexed). May exceed page size for screen/history tags. */
  uint32_t y;
} GhosttyPointCoordinate;

/**
 * Point reference tag.
 *
 * Determines which coordinate system a point uses.
 *
 * @ingroup point
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Active area where the cursor can move. */
  GHOSTTY_POINT_TAG_ACTIVE = 0,

  /** Visible viewport (changes when scrolled). */
  GHOSTTY_POINT_TAG_VIEWPORT = 1,

  /** Full screen including scrollback. */
  GHOSTTY_POINT_TAG_SCREEN = 2,

  /** Scrollback history only (before active area). */
  GHOSTTY_POINT_TAG_HISTORY = 3,
  GHOSTTY_POINT_TAG_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
  } GhosttyPointTag;

/**
 * Point value union.
 *
 * @ingroup point
 */
typedef union {
  /** Coordinate (used for all tag variants). */
  GhosttyPointCoordinate coordinate;

  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[2];
} GhosttyPointValue;

/**
 * Tagged union for a point in the terminal grid.
 *
 * @ingroup point
 */
typedef struct {
  GhosttyPointTag tag;
  GhosttyPointValue value;
} GhosttyPoint;

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_POINT_H */
