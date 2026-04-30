/**
 * @file selection.h
 *
 * Selection range type for specifying a region of terminal content.
 */

#ifndef GHOSTTY_VT_SELECTION_H
#define GHOSTTY_VT_SELECTION_H

#include <stdbool.h>
#include <stddef.h>
#include <ghostty/vt/grid_ref.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup selection Selection
 *
 * A selection range defined by two grid references that identifies a
 * contiguous or rectangular region of terminal content.
 *
 * @{
 */

/**
 * A selection range defined by two grid references.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 *
 * @ingroup selection
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttySelection). */
  size_t size;

  /** Start of the selection range (inclusive). */
  GhosttyGridRef start;

  /** End of the selection range (inclusive). */
  GhosttyGridRef end;

  /** Whether the selection is rectangular (block) rather than linear. */
  bool rectangle;
} GhosttySelection;

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SELECTION_H */
