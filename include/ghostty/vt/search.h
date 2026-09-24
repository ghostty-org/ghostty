/**
 * @file search.h
 *
 * Search terminal contents, including scrollback, for a string.
 */

#ifndef GHOSTTY_VT_SEARCH_H
#define GHOSTTY_VT_SEARCH_H

#include <stddef.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup search Search
 *
 * Search a terminal for a string, covering the active area and
 * scrollback of both the primary and alternate screens.
 *
 * A GhosttySearch searches the terminal it was created with for a
 * needle set with GHOSTTY_SEARCH_OPT_NEEDLE. It handles the hard
 * parts of terminal search internally: results stay in sync with the
 * live screens, survive primary/alternate screen switches (entering
 * and leaving a fullscreen app such as vim does not restart a
 * scrollback search), and recover from resize, reflow, resets, and
 * scrollback pruning.
 *
 * A search starts idle. Setting the needle starts the search,
 * changing it restarts the search from scratch, and clearing it
 * returns the search to idle. Matching is byte-exact except ASCII
 * letters, which compare case-insensitively.
 *
 * ## Driving a search
 *
 * Searching a large scrollback takes time, so the work is split into
 * small steps the caller drives so that the caller can control
 * performance more directly:
 *
 * - ghostty_search_tick() makes a bounded amount of progress on data
 *   the search has already copied. It never touches the terminal, 
 *   meaning it can be safely called from a thread.
 * - ghostty_search_feed() reads the terminal to copy in more data and
 *   pick up terminal changes. Feeding is the only way the search
 *   learns that the terminal changed, so keep feeding periodically
 *   while the search is in use. This requires exclusive terminal access.
 * - ghostty_search_run() is a blocking convenience that feeds and
 *   ticks until the search is caught up.
 *
 * GHOSTTY_SEARCH_STATUS_COMPLETE means the search is caught up with
 * the terminal as of the last feed. It never means finished forever,
 * since later terminal writes require another feed to be seen.
 *
 * ## Matches are selections
 *
 * Every match is returned as a GhosttySelection snapshot with
 * rectangle set to false, so the existing selection APIs all work on
 * matches: ghostty_terminal_selection_format_buf() to copy the
 * matched text, ghostty_terminal_point_from_grid_ref() with
 * GHOSTTY_POINT_TAG_VIEWPORT to position highlight rectangles,
 * ghostty_terminal_selection_contains() for hit testing, and
 * ghostty_terminal_set() with GHOSTTY_TERMINAL_OPT_SELECTION to make
 * a match the terminal's selection.
 *
 * Returned matches follow the usual snapshot lifetime rules: they are
 * only valid until the next operation that modifies the terminal,
 * including ghostty_terminal_vt_write(), resize, reset, and free.
 * Read matches after a feed, use them before the terminal changes
 * again, and re-read them rather than caching them. The selected
 * match is kept accurate internally across terminal changes, so the
 * safe way to follow a match is to re-read
 * GHOSTTY_SEARCH_DATA_SELECTED_MATCH after each feed.
 *
 * ## Lifetime
 *
 * The search borrows the terminal it was created with and never frees
 * it. Any number of searches, alongside other terminal readers such
 * as formatters and render states, may share one terminal.
 *
 * The search and its terminal can be freed in either order. Freeing
 * the search first releases tracked state it holds within the
 * terminal. If the terminal is freed first, the search detects this:
 * calls that need the terminal return GHOSTTY_INVALID_VALUE, reads
 * return whatever the search last saw, and ghostty_search_free()
 * releases only search-owned memory. A search cannot be rebound, so
 * searching another terminal means creating a new search.
 *
 * ## Threading
 *
 * The library creates no threads. Calls on one GhosttySearch are not
 * safe to make concurrently with each other, so the caller must
 * serialize them.
 *
 * Functions that touch the terminal (ghostty_search_new(),
 * ghostty_search_feed(), ghostty_search_run(), ghostty_search_set()
 * with the needle and select options, and ghostty_search_free()) must
 * also be serialized with all other access to the same terminal.
 *
 * Everything else (ghostty_search_tick(), ghostty_search_get(), and
 * ghostty_search_get_multi()) only touches memory owned by the search
 * and is safe to call while another thread modifies the terminal.
 * This split is how Ghostty runs search on a background thread: tick
 * freely, and take the terminal lock only to feed. Reading returned
 * match values is always safe, but passing them to APIs that take the
 * terminal follows the terminal serialization rule above.
 *
 * ## Example
 *
 * @snippet c-vt-search/src/main.c search-main
 *
 * @{
 */

/**
 * Progress state of a search.
 *
 * @ingroup search
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * ghostty_search_tick() can make progress without terminal access.
   */
  GHOSTTY_SEARCH_STATUS_RUNNING = 0,

  /**
   * Blocked until ghostty_search_feed(). This is also the state right
   * after a needle is set, since the search has not yet seen the
   * terminal.
   */
  GHOSTTY_SEARCH_STATUS_FEED_REQUIRED = 1,

  /**
   * Caught up with the terminal state as of the last feed. This never
   * means finished forever, since later terminal writes require
   * another feed to be seen. A search with no needle set also reports
   * complete, since there is nothing to look for.
   */
  GHOSTTY_SEARCH_STATUS_COMPLETE = 2,

  GHOSTTY_SEARCH_STATUS_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySearchStatus;

/**
 * Scroll policy applied when a match becomes selected via
 * GHOSTTY_SEARCH_OPT_SELECT_NEXT or GHOSTTY_SEARCH_OPT_SELECT_PREV.
 *
 * @ingroup search
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Scroll the viewport so the match is visible, only if it is not
   * already visible. This is the default. */
  GHOSTTY_SEARCH_SCROLL_IF_NEEDED = 0,

  /** Never scroll the viewport. */
  GHOSTTY_SEARCH_SCROLL_NONE = 1,

  GHOSTTY_SEARCH_SCROLL_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySearchScroll;

/**
 * Data fields readable with ghostty_search_get(). The output value
 * type is documented per field.
 *
 * All reads reflect the terminal's active screen as of the last feed.
 * When the running application switches to the alternate screen, the
 * next feed switches counts, matches, and selection to that screen's
 * results. Primary screen results, including completed scrollback
 * searches, are retained and restored on the way back.
 *
 * @ingroup search
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Current search status: GhosttySearchStatus*. */
  GHOSTTY_SEARCH_DATA_STATUS = 0,

  /**
   * The needle this search is looking for: GhosttyString*. The bytes
   * are borrowed from the search and remain valid until the needle is
   * changed or the search is freed. Returns GHOSTTY_NO_VALUE when no
   * needle is set.
   */
  GHOSTTY_SEARCH_DATA_NEEDLE = 1,

  /**
   * Total matches found so far on the active screen: size_t*. Zero
   * until the first feed.
   */
  GHOSTTY_SEARCH_DATA_TOTAL_MATCHES = 2,

  /**
   * Index of the selected match: size_t*. This indexes the newest to
   * oldest ordering of GHOSTTY_SEARCH_DATA_MATCHES, where 0 is the
   * newest match, so a "k of n" find bar renders index + 1 of
   * GHOSTTY_SEARCH_DATA_TOTAL_MATCHES. Returns GHOSTTY_NO_VALUE when
   * nothing is selected.
   */
  GHOSTTY_SEARCH_DATA_SELECTED_INDEX = 3,

  /**
   * The selected match: GhosttySelection*. This is an untracked
   * snapshot with standard GhosttySelection lifetime rules. Returns
   * GHOSTTY_NO_VALUE when nothing is selected.
   */
  GHOSTTY_SEARCH_DATA_SELECTED_MATCH = 4,

  /**
   * All matches on the active screen, ordered newest to oldest, from
   * the bottom of the active area up through scrollback:
   * GhosttySelectionBuffer*. Set ptr to NULL with cap 0 to query the
   * required capacity. An undersized buffer returns
   * GHOSTTY_OUT_OF_SPACE with the required capacity in len.
   */
  GHOSTTY_SEARCH_DATA_MATCHES = 5,

  /**
   * Matches on the pages covering the viewport, for drawing highlight
   * rectangles: GhosttySelectionBuffer*. The list is computed during
   * feeds and cached, so it reflects the viewport as of the last
   * feed.
   *
   * Matches are found a page at a time, so the list can include
   * matches slightly outside the visible viewport when they share a
   * page with it. Ghostty's own renderer behaves the same way.
   * Converting each match to viewport coordinates with
   * ghostty_terminal_point_from_grid_ref() clips this naturally: skip
   * matches that fail the conversion or whose row is beyond the
   * visible row count.
   */
  GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES = 6,

  /** Current scroll policy: GhosttySearchScroll*. */
  GHOSTTY_SEARCH_DATA_SELECT_SCROLL = 7,

  GHOSTTY_SEARCH_DATA_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySearchData;

/**
 * Options writable with ghostty_search_set(). The value type, and
 * what a NULL value means, is documented per option.
 *
 * @ingroup search
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /**
   * Set the needle to search for: const GhosttyString*. The bytes are
   * copied, so the caller's memory does not need to outlive the call.
   * Matching is byte-exact except ASCII letters, which compare
   * case-insensitively.
   *
   * Changing the needle restarts the search from scratch and drops
   * all results. As an exception, setting a needle equal to the current
   * one (compared the same way as matching) keeps existing results,
   * so find bars can resubmit freely. A NULL or empty value clears
   * the needle and returns the search to idle.
   *
   * Replacing or clearing a needle releases tracked state held
   * within the terminal, so the caller must serialize this with all
   * other access to the same terminal. Returns GHOSTTY_INVALID_VALUE
   * after the terminal was freed.
   */
  GHOSTTY_SEARCH_OPT_NEEDLE = 0,

  /**
   * Select the next match, moving toward older content: from the
   * bottom of the screen upward into history, the direction a search
   * from the prompt usually wants. Wraps around past the oldest
   * match.
   *
   * The value must be NULL. It is reserved for future use.
   *
   * This catches up with the terminal first, so it is safe to call at
   * any time relative to feeds. The viewport scrolls to the newly
   * selected match according to GHOSTTY_SEARCH_OPT_SELECT_SCROLL.
   * This reads the terminal, so the caller must serialize it with all
   * other access to the same terminal. Returns GHOSTTY_NO_VALUE when
   * there are no matches.
   */
  GHOSTTY_SEARCH_OPT_SELECT_NEXT = 1,

  /**
   * Select the previous match, moving toward newer content, wrapping
   * around past the newest match. Otherwise identical to
   * GHOSTTY_SEARCH_OPT_SELECT_NEXT.
   */
  GHOSTTY_SEARCH_OPT_SELECT_PREV = 2,

  /**
   * Set the scroll policy applied by the select options: const
   * GhosttySearchScroll*. The policy persists until changed. A NULL
   * value resets it to GHOSTTY_SEARCH_SCROLL_IF_NEEDED. This only
   * modifies search-owned state and never reads the terminal.
   */
  GHOSTTY_SEARCH_OPT_SELECT_SCROLL = 3,

  GHOSTTY_SEARCH_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttySearchOption;

/**
 * Create a search bound to a terminal.
 *
 * The search borrows the terminal and never frees it. The search and
 * the terminal can be freed in either order; see ghostty_search_free().
 *
 * The search starts idle with no needle: it reports
 * GHOSTTY_SEARCH_STATUS_COMPLETE and finds nothing. Set
 * GHOSTTY_SEARCH_OPT_NEEDLE to start searching.
 *
 * Creation is cheap and does not read terminal contents, but it
 * registers the search with the terminal so the two can be freed in
 * any order. The caller must serialize this call with all other
 * access to the same terminal.
 *
 * @param allocator Allocator, or NULL for the default allocator
 * @param out_search Receives the created search handle
 * @param terminal Terminal to bind the search to
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if
 *         out_search or terminal is invalid, or GHOSTTY_OUT_OF_MEMORY
 *         if allocation fails
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_new(
                                    const GhosttyAllocator* allocator,
                                    GhosttySearch* out_search,
                                    GhosttyTerminal terminal);

/**
 * Free a search.
 *
 * If the bound terminal is still alive, this releases tracked state
 * the search holds within it, so the caller must serialize this call
 * with all other access to the same terminal. If the terminal was
 * already freed, the search has been detached and this releases only
 * search-owned memory. Passing NULL is allowed and is a no-op.
 *
 * @param search Search handle to free
 *
 * @ingroup search
 */
GHOSTTY_API void ghostty_search_free(GhosttySearch search);

/**
 * Make a bounded amount of search progress.
 *
 * This only works on data the search has already copied and never
 * reads the terminal, so it is safe to call while another thread
 * modifies the terminal. Call it in a loop while the status is
 * GHOSTTY_SEARCH_STATUS_RUNNING. When the status becomes
 * GHOSTTY_SEARCH_STATUS_FEED_REQUIRED, call ghostty_search_feed() to
 * unblock it.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_status Receives the status after the tick (may be NULL)
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if
 *         search is NULL
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_tick(
                                    GhosttySearch search,
                                    GhosttySearchStatus* out_status);

/**
 * Read the terminal to update the search.
 *
 * Each feed catches the search up with the terminal: it reconciles
 * the tracked screens against the live ones, re-scans the active
 * area, refreshes the viewport match list, gives the scrollback
 * searcher its next chunk of data, and prunes results that scrollback
 * eviction invalidated. Feeding is also the only way the search
 * learns about terminal changes, so keep feeding periodically while
 * the search is in use, even after it reports complete.
 *
 * This reads the terminal, so the caller must serialize it with all
 * other access to the same terminal. Each call does a bounded amount
 * of work so that any caller-held terminal lock is held only briefly.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if
 *         search is NULL or the terminal was freed
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_feed(GhosttySearch search);

/**
 * Feed and tick until the search is caught up with the terminal.
 *
 * This is a blocking convenience for one-shot and single-threaded
 * embedders. It always performs at least one feed, so it also picks
 * up any terminal changes since the last feed, then loops until the
 * status is GHOSTTY_SEARCH_STATUS_COMPLETE. Searching a large
 * scrollback can take a while, so interactive embedders should drive
 * ghostty_search_tick() and ghostty_search_feed() themselves.
 *
 * This reads the terminal for the entire call, so the caller must
 * serialize it with all other access to the same terminal.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, or GHOSTTY_INVALID_VALUE if
 *         search is NULL or the terminal was freed
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_run(GhosttySearch search);

/**
 * Write an option to a search.
 *
 * The value type, and what a NULL value means, depends on the option
 * and is documented by GhosttySearchOption. The needle and select
 * options touch the terminal, so the caller must serialize those
 * calls with all other access to the same terminal.
 * GHOSTTY_SEARCH_OPT_SELECT_SCROLL only modifies search-owned state.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option Option to write
 * @param value Pointer to the input value for the option. The meaning
 *              of NULL is documented per option.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if a select
 *         option found no matches, GHOSTTY_OUT_OF_MEMORY if
 *         allocation fails, or GHOSTTY_INVALID_VALUE if search,
 *         option, or value is invalid or the option needs a terminal
 *         that was already freed
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_set(
                                    GhosttySearch search,
                                    GhosttySearchOption option,
                                    const void* value);

/**
 * Read a data field from a search.
 *
 * The output value type depends on data and is documented by
 * GhosttySearchData. This never reads the terminal, so it is safe to
 * call while another thread modifies the terminal. Returned
 * selections are untracked snapshots with standard GhosttySelection
 * lifetime rules.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param data Data field to read
 * @param value Output pointer whose type depends on data
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the
 *         requested data has no value, GHOSTTY_OUT_OF_SPACE if a
 *         provided GhosttySelectionBuffer is too small (required
 *         capacity in its len), GHOSTTY_OUT_OF_MEMORY if collecting
 *         viewport matches fails, or GHOSTTY_INVALID_VALUE if search,
 *         data, or value is invalid
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_get(
                                    GhosttySearch search,
                                    GhosttySearchData data,
                                    void* value);

/**
 * Read multiple data fields from a search in a single call.
 *
 * This is an optimization over calling ghostty_search_get() multiple
 * times. Each entry in values must point to storage of the type
 * documented by the corresponding GhosttySearchData key.
 *
 * If any individual read fails, the function returns that error and
 * writes the index of the failing key to out_written when out_written
 * is non-NULL. Earlier keys have already been written. On success,
 * out_written receives count when non-NULL. A too-small
 * GhosttySelectionBuffer stops the batch with GHOSTTY_OUT_OF_SPACE at
 * that key's index with the required capacity in its len, so order
 * buffer-valued keys after scalar keys.
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param count Number of data fields to read
 * @param keys Data fields to read (must not be NULL)
 * @param values Output pointers corresponding to keys (must not be NULL)
 * @param out_written Optional number of fields read, or failing index
 *                    on error
 * @return GHOSTTY_SUCCESS on success, or the first failing read's
 *         result
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_get_multi(
                                    GhosttySearch search,
                                    size_t count,
                                    const GhosttySearchData* keys,
                                    void** values,
                                    size_t* out_written);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_SEARCH_H */
