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
 * A grid reference is a reference to a specific cell position in the 
 * terminal. Obtain a grid reference from `ghostty_terminal_grid_ref`
 * for untracked or `ghostty_terminal_grid_ref_track` for tracked. Untracked
 * vs tracked is explained next.
 *
 * Important: The grid reference APIs are not meant to be used as the core of a render
 * loop. They are not built to sustain the framerates needed for rendering large
 * screens. Use the render state API for that.
 *
 * ## Untracked vs Tracked References
 *  
 * ### Untracked Reference
 *
 * An untracked grid reference is a value type that snapshots a specific
 * cell. It is only valid until the next update to the terminal instance.
 * There is no guarantee that it will remain valid after any operation,
 * even if a seemingly unrelated part of the grid is changed. These are meant
 * to be read and have their values cached immediately after obtaining it.
 *
 * An untracked grid reference has a performance cost in its initial lookup,
 * but doesn't affect the ongoing performance of the terminal in any way,
 * since it is a one-time snapshot.
 *
 * ### Tracked Reference
 *
 * A tracked grid reference follows its cell across normal screen operations.
 * For example scrolling, scrollback pruning, resize/reflow, and other
 * terminal mutations update the tracked reference automatically.
 * 
 * A tracked reference can still lose its original semantic location. This can
 * happen when the underlying grid is reset, pruned, or otherwise discarded in a
 * way that cannot be mapped to a meaningful new cell. In that state,
 * ghostty_tracked_grid_ref_has_value() returns false and
 * ghostty_tracked_grid_ref_snapshot() / ghostty_tracked_grid_ref_point() return
 * GHOSTTY_NO_VALUE. The handle remains valid, and callers may move it to a new
 * point with ghostty_tracked_grid_ref_set().
 *
 * To read cell data from a tracked reference, first snapshot it with
 * ghostty_tracked_grid_ref_snapshot(). The returned `GhosttyGridRef` is again
 * an untracked reference and follows the same short lifetime rules as any other
 * untracked grid reference.
 *
 * A tracked reference belongs to the terminal screen/page-list that was active
 * when it was created or last set. Converting it to a point uses that owning
 * screen/page-list, even if the terminal has since switched between primary and
 * alternate screens. Calling ghostty_tracked_grid_ref_set() resolves the new
 * point against the terminal's currently active screen/page-list and may move
 * the tracked reference between screens.
 *
 * Tracked references are owned by the caller and must be freed with
 * ghostty_tracked_grid_ref_free(). If the terminal that created a tracked
 * reference is freed first, the handle remains valid only for tracked-grid-ref
 * APIs: it reports no value and can still be freed.
 *
 * Each tracked reference adds bookkeeping to terminal mutations. Use them 
 * sparingly for long-lived anchors such as selections, search state, marks, 
 * or application-side bookmarks.
 *
 * ## Lifetime
 *
 * An untracked reference is a snapshot. It doesn't need to be freed.
 * The safety of accessing the value is documented explicitly above: it
 * is only safe to access any data until the next terminal mutating
 * operation (including free).
 *
 * A tracked reference is allocated and must be freed when it is no
 * longer needed. A tracked reference may outlive the terminal that created it;
 * after terminal free, it reports no value and can still be freed.
 *
 * ## Examples
 *
 * @snippet c-vt-grid-traverse/src/main.c grid-ref-traverse
 * @snippet c-vt-grid-ref-tracked/src/main.c grid-ref-tracked
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
