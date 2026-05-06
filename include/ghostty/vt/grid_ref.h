/**
 * @file grid_ref.h
 *
 * Terminal grid reference type for referencing a resolved position in the
 * terminal grid.
 */

#ifndef GHOSTTY_VT_GRID_REF_H
#define GHOSTTY_VT_GRID_REF_H

#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/style.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup grid_ref Grid Reference
 *
 * A grid reference is a resolved reference to a specific cell position in the
 * terminal's internal page structure. Obtain a grid reference from
 * ghostty_terminal_grid_ref(), then extract the cell or row via
 * ghostty_grid_ref_cell() and ghostty_grid_ref_row().
 *
 * A grid reference is only valid until the next update to the terminal
 * instance. There is no guarantee that a grid reference will remain
 * valid after ANY operation, even if a seemingly unrelated part of
 * the grid is changed, so any information related to the grid reference
 * should be read and cached immediately after obtaining the grid reference.
 *
 * This API is not meant to be used as the core of render loop. It isn't 
 * built to sustain the framerates needed for rendering large screens. 
 * Use the render state API for that. 
 *
 * ## Example
 *
 * @snippet c-vt-grid-traverse/src/main.c grid-ref-traverse
 *
 * @{
 */

/**
 * A resolved reference to a terminal cell position.
 *
 * This is a sized struct. Use GHOSTTY_INIT_SIZED() to initialize it.
 *
 * @ingroup grid_ref
 */
typedef struct {
  size_t size;
  void *node;
  uint16_t x;
  uint16_t y;
} GhosttyGridRef;

/**
 * Get the cell from a grid reference.
 *
 * @param ref Pointer to the grid reference
 * @param[out] out_cell On success, set to the cell at the ref's position (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_cell(const GhosttyGridRef *ref,
                                    GhosttyCell *out_cell);

/**
 * Get the row from a grid reference.
 *
 * @param ref Pointer to the grid reference
 * @param[out] out_row On success, set to the row at the ref's position (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_row(const GhosttyGridRef *ref,
                                   GhosttyRow *out_row);

/**
 * Get the grapheme cluster codepoints for the cell at the grid reference's
 * position.
 *
 * Writes the full grapheme cluster (the cell's primary codepoint followed by
 * any combining codepoints) into the provided buffer. If the cell has no text,
 * out_len is set to 0 and GHOSTTY_SUCCESS is returned.
 *
 * If the buffer is too small (or NULL), the function returns
 * GHOSTTY_OUT_OF_SPACE and writes the required number of codepoints to
 * out_len. The caller can then retry with a sufficiently sized buffer.
 *
 * @param ref Pointer to the grid reference
 * @param buf Output buffer of uint32_t codepoints (may be NULL)
 * @param buf_len Number of uint32_t elements in the buffer
 * @param[out] out_len On success, the number of codepoints written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size in codepoints.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL, GHOSTTY_OUT_OF_SPACE if the buffer is too small
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_graphemes(const GhosttyGridRef *ref,
                                         uint32_t *buf,
                                         size_t buf_len,
                                         size_t *out_len);

/**
 * Get the hyperlink URI for the cell at the grid reference's position.
 *
 * Writes the URI bytes into the provided buffer. If the cell has no
 * hyperlink, out_len is set to 0 and GHOSTTY_SUCCESS is returned.
 *
 * If the buffer is too small (or NULL), the function returns
 * GHOSTTY_OUT_OF_SPACE and writes the required number of bytes to
 * out_len. The caller can then retry with a sufficiently sized buffer.
 *
 * @param ref Pointer to the grid reference
 * @param buf Output buffer for the URI bytes (may be NULL)
 * @param buf_len Size of the output buffer in bytes
 * @param[out] out_len On success, the number of bytes written. On
 *             GHOSTTY_OUT_OF_SPACE, the required buffer size in bytes.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL, GHOSTTY_OUT_OF_SPACE if the buffer is too small
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_hyperlink_uri(
    const GhosttyGridRef *ref,
    uint8_t *buf,
    size_t buf_len,
    size_t *out_len);

/**
 * Get the style of the cell at the grid reference's position.
 *
 * @param ref Pointer to the grid reference
 * @param[out] out_style On success, set to the cell's style (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_style(const GhosttyGridRef *ref,
                                     GhosttyStyle *out_style);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_GRID_REF_H */
