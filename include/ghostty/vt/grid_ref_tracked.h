/**
 * @file grid_ref_tracked.h
 *
 * Tracked terminal grid references.
 */

#ifndef GHOSTTY_VT_GRID_REF_TRACKED_H
#define GHOSTTY_VT_GRID_REF_TRACKED_H

#include <stdbool.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/point.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Tracked grid references are owned grid references that move with the
 * terminal. See @ref grid_ref for the full overview of tracked and untracked
 * grid reference behavior.
 *
 * @ingroup grid_ref
 */

/**
 * Free a tracked grid reference.
 *
 * Passing NULL is allowed and has no effect. A tracked reference may be freed
 * after the terminal that created it is freed.
 *
 * @param ref Tracked grid reference to free.
 *
 * @ingroup grid_ref
 */
GHOSTTY_API void ghostty_tracked_grid_ref_free(GhosttyTrackedGridRef ref);

/**
 * Return whether a tracked grid reference currently has a meaningful value.
 *
 * If the terminal that created the tracked reference has been freed, this
 * returns false.
 *
 * @param ref Tracked grid reference.
 * @return true if the reference currently has a meaningful value.
 *
 * @ingroup grid_ref
 */
GHOSTTY_API bool ghostty_tracked_grid_ref_has_value(
    GhosttyTrackedGridRef ref);

/**
 * Convert a tracked grid reference to a point in the requested coordinate
 * space.
 *
 * This is the tracked equivalent of ghostty_terminal_point_from_grid_ref().
 * Unlike snapshotting, this does not expose an intermediate untracked
 * GhosttyGridRef.
 *
 * A tracked reference is resolved against the terminal screen/page-list that
 * currently owns the reference. If the terminal has switched between primary
 * and alternate screens since the reference was created or last set, this may
 * be different from the terminal's currently active screen.
 *
 * If the tracked reference no longer has a meaningful value, this returns
 * GHOSTTY_NO_VALUE. GHOSTTY_NO_VALUE is also returned when the reference cannot
 * be represented in the requested coordinate space, including after the
 * terminal that created the tracked reference has been freed.
 *
 * @param ref Tracked grid reference.
 * @param tag Coordinate space to convert into.
 * @param[out] out_point On success, receives the coordinate. May be NULL.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if ref is invalid,
 *         or GHOSTTY_NO_VALUE if there is no representable value.
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_point(
    GhosttyTrackedGridRef ref,
    GhosttyPointTag tag,
    GhosttyPointCoordinate *out_point);

/**
 * Move an existing tracked grid reference to a new terminal point.
 *
 * On success, the tracked reference begins tracking the new point and any prior
 * "no value" state is cleared. On GHOSTTY_OUT_OF_MEMORY, the original tracked
 * reference is left unchanged.
 *
 * The terminal must be the same terminal that created the tracked reference.
 * The point is resolved against the terminal screen/page-list that is active at
 * the time this function is called. If the terminal has switched between
 * primary and alternate screens, this may move the tracked reference from one
 * screen/page-list to the other.
 *
 * @param ref Tracked grid reference.
 * @param terminal Terminal instance that owns the reference.
 * @param point New point to track.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if ref, terminal,
 *         or point is invalid, or GHOSTTY_OUT_OF_MEMORY if allocation fails.
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_set(
    GhosttyTrackedGridRef ref,
    GhosttyTerminal terminal,
    GhosttyPoint point);

/**
 * Snapshot a tracked grid reference into a regular GhosttyGridRef.
 *
 * The returned GhosttyGridRef is an untracked snapshot and has the same
 * lifetime rules as ghostty_terminal_grid_ref(): it is only valid until the
 * next terminal update. Snapshot immediately before calling
 * ghostty_grid_ref_cell(), ghostty_grid_ref_row(),
 * ghostty_grid_ref_graphemes(), ghostty_grid_ref_hyperlink_uri(), or
 * ghostty_grid_ref_style().
 *
 * If the tracked reference no longer has a meaningful value, this returns
 * GHOSTTY_NO_VALUE. This includes references whose owning terminal has been
 * freed.
 *
 * @param ref Tracked grid reference.
 * @param[out] out_ref On success, receives an untracked snapshot. May be NULL.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if ref is invalid,
 *         or GHOSTTY_NO_VALUE if the tracked location was discarded.
 *
 * @ingroup grid_ref
 */
GHOSTTY_API GhosttyResult ghostty_tracked_grid_ref_snapshot(
    GhosttyTrackedGridRef ref,
    GhosttyGridRef *out_ref);

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_GRID_REF_TRACKED_H */
