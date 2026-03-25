/**
 * @file point.h
 *
 * Terminal point types for referencing locations in the terminal grid.
 */

#ifndef GHOSTTY_VT_POINT_H
#define GHOSTTY_VT_POINT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup point Point
 *
 * Types for referencing x/y positions in the terminal grid under
 * different coordinate systems (active area, viewport, full screen,
 * scrollback history).
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
typedef enum {
  /** Active area where the cursor can move. */
  GHOSTTY_POINT_TAG_ACTIVE = 0,

  /** Visible viewport (changes when scrolled). */
  GHOSTTY_POINT_TAG_VIEWPORT = 1,

  /** Full screen including scrollback. */
  GHOSTTY_POINT_TAG_SCREEN = 2,

  /** Scrollback history only (before active area). */
  GHOSTTY_POINT_TAG_HISTORY = 3,
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
