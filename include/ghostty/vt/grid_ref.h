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

/** @addtogroup grid_ref
 *
 * A grid reference points at one cell in the terminal.
 *
 * An untracked reference is a snapshot that is only valid until the next change
 * to the terminal. A tracked reference follows its cell. Use one to read
 * particular cells. They aren't fast enough to draw a frame, so use @ref render
 * for that.
 *
 * ## Example
 *
 * @code{.c}
 * GhosttyGridRef ref = {0};
 * GhosttyPoint point = {
 *     .tag = GHOSTTY_POINT_TAG_ACTIVE,
 *     .value = { .coordinate = { .x = 4, .y = 0 } },
 * };
 *
 * if (ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS) {
 *     GhosttyCell cell;
 *     ghostty_grid_ref_cell(&ref, &cell);
 * }
 * @endcode
 *
 * Full program: @ref c-vt-grid-traverse/src/main.c
 *
 * The @ref guide-grid "Grid guide" covers coordinates, both kinds of reference,
 * and when each one dies.
 *
 * @{
 */

/**
 * A reference to a single cell in the terminal grid.
 *
 * You don't fill in a grid reference yourself. Get one from the library,
 * usually with ghostty_terminal_grid_ref(), and then pass it to the
 * ghostty_grid_ref_* functions to read the cell, its row, its style, and
 * more.
 *
 * A grid reference is an untracked snapshot. It is only valid until the
 * next call that changes the terminal, such as ghostty_terminal_vt_write()
 * or ghostty_terminal_resize(). To keep pointing at the same cell across
 * changes, use a tracked reference instead (see GhosttyTrackedGridRef).
 *
 * We can't detect a stale reference, so nothing returns an error for one. A
 * reference holds a raw pointer into the terminal's page list. If that page is
 * still there, you read whatever is at that position now, which may be a
 * different cell. If the page was freed, you read freed memory, and that's
 * undefined behavior. Don't use a reference after the terminal changes.
 *
 * Start with a zero-initialized value. A zeroed reference doesn't point at
 * any cell, and the ghostty_grid_ref_* functions return
 * GHOSTTY_INVALID_VALUE for it.
 *
 * @code{.c}
 * GhosttyGridRef ref = {0};
 * GhosttyPoint point = {
 *     .tag = GHOSTTY_POINT_TAG_ACTIVE,
 *     .value = { .coordinate = { .x = 4, .y = 0 } },
 * };
 *
 * if (ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS) {
 *     GhosttyCell cell;
 *     ghostty_grid_ref_cell(&ref, &cell);
 * }
 * @endcode
 *
 * The fields describe where the cell lives in the terminal's internal
 * storage. Treat them as read-only. In particular, `x` and `y` are not
 * screen coordinates. To get the cell's position on the screen, call
 * ghostty_terminal_point_from_grid_ref().
 *
 * The layout of this struct is frozen. It is 16 bytes on 64-bit targets
 * and 8 bytes on 32-bit targets such as wasm32. If it ever needs to hold
 * more, that will be a new type.
 *
 * @ingroup grid_ref
 */
typedef struct {
  /** The internal storage page that holds the cell. */
  void *node;

  /** The cell's column within its page. */
  uint16_t x;

  /** The cell's row within its page. */
  uint16_t y;
} GhosttyGridRef;

/**
 * Get the cell from a grid reference.
 *
 * @param ref Pointer to the grid reference (NULL returns
 *            GHOSTTY_INVALID_VALUE)
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
 * @param ref Pointer to the grid reference (NULL returns
 *            GHOSTTY_INVALID_VALUE)
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
 * any combining codepoints) into the provided buffer. Both @p buf_len and
 * @p out_written count codepoints, not bytes.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE, sets
 * @p out_written to the number of codepoints needed, and leaves @p buf
 * unchanged. To get the count without copying anything, pass NULL for
 * @p buf and 0 for @p buf_len. A cell with no text returns GHOSTTY_SUCCESS
 * with @p out_written set to 0.
 *
 * Most cells hold a single codepoint, so a small fixed buffer usually
 * works. Fall back to a heap buffer for longer clusters:
 *
 * @code{.c}
 * uint32_t stack[8];
 * uint32_t *codepoints = stack;
 * size_t count = 0;
 * GhosttyResult result = ghostty_grid_ref_graphemes(&ref, stack, 8, &count);
 * if (result == GHOSTTY_OUT_OF_SPACE) {
 *   codepoints = malloc(count * sizeof(uint32_t));
 *   result = ghostty_grid_ref_graphemes(&ref, codepoints, count, &count);
 * }
 * if (result == GHOSTTY_SUCCESS) {
 *   // codepoints[0] through codepoints[count - 1] hold the cluster
 * }
 * if (codepoints != stack) free(codepoints);
 * @endcode
 *
 * @param ref Pointer to the grid reference (NULL returns
 *            GHOSTTY_INVALID_VALUE)
 * @param buf Buffer to write the codepoints into. May be NULL if @p buf_len
 *            is 0.
 * @param buf_len Number of uint32_t elements @p buf can hold
 * @param[out] out_written The number of codepoints written, or the number
 *             needed if the result is GHOSTTY_OUT_OF_SPACE (NULL returns
 *             GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL, GHOSTTY_OUT_OF_SPACE if the buffer is too small
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_graphemes(const GhosttyGridRef *ref,
                                         uint32_t *buf,
                                         size_t buf_len,
                                         size_t *out_written);

/**
 * Get the hyperlink URI for the cell at the grid reference's position.
 *
 * Writes the URI bytes into the provided buffer.
 *
 * The URI is not NUL-terminated.
 *
 * If @p buf is too small, this returns GHOSTTY_OUT_OF_SPACE, sets
 * @p out_written to the size needed, and leaves @p buf unchanged. To get
 * the size without copying anything, pass NULL for @p buf and 0 for
 * @p buf_len. A cell with no hyperlink returns GHOSTTY_SUCCESS with
 * @p out_written set to 0.
 *
 * URIs can be long, so asking for the size first is often simplest:
 *
 * @code{.c}
 * size_t len = 0;
 * if (ghostty_grid_ref_hyperlink_uri(&ref, NULL, 0, &len) == GHOSTTY_OUT_OF_SPACE) {
 *   uint8_t *uri = malloc(len);
 *   ghostty_grid_ref_hyperlink_uri(&ref, uri, len, &len);
 *   // uri holds len bytes
 *   free(uri);
 * }
 * @endcode
 *
 * @param ref Pointer to the grid reference (NULL returns
 *            GHOSTTY_INVALID_VALUE)
 * @param buf Buffer to write the URI into. May be NULL if @p buf_len is 0.
 * @param buf_len Size of @p buf in bytes
 * @param[out] out_written The number of bytes written, or the size needed
 *             if the result is GHOSTTY_OUT_OF_SPACE (NULL returns
 *             GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the ref's
 *         node is NULL, GHOSTTY_OUT_OF_SPACE if the buffer is too small
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_grid_ref_hyperlink_uri(
    const GhosttyGridRef *ref,
    uint8_t *buf,
    size_t buf_len,
    size_t *out_written);

/**
 * Get the style of the cell at the grid reference's position.
 *
 * @param ref Pointer to the grid reference (NULL returns
 *            GHOSTTY_INVALID_VALUE)
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
