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

/** @addtogroup search
 *
 * Search a terminal for a string, covering the active area and scrollback of
 * both the primary and alternate screens.
 *
 * You need a terminal to search. For a one-shot search, ghostty_search_run()
 * does all of the work. For a find bar over a lot of scrollback, you decide when
 * the work happens.
 *
 * ## Example
 *
 * @snippet c-vt-search/src/main.c search-main
 *
 * Full program: @ref c-vt-search/src/main.c
 *
 * The @ref guide-search "Search guide" covers driving a search, reading
 * matches, lifetime, and threads.
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
 * ghostty_search_select_next() or ghostty_search_select_prev().
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
  /**
   * Not a real data type. ghostty_search_get() returns GHOSTTY_INVALID_VALUE
   * for it. Its value is 0, so a zeroed or uninitialized variable is never
   * mistaken for a real data type.
   */
  GHOSTTY_SEARCH_DATA_INVALID = 0,

  /** Current search status: GhosttySearchStatus*. */
  GHOSTTY_SEARCH_DATA_STATUS = 1,

  /**
   * The needle this search is looking for: GhosttyString*. The bytes
   * are borrowed from the search and remain valid until the needle is
   * changed or the search is freed. Returns GHOSTTY_NO_VALUE when no
   * needle is set.
   */
  GHOSTTY_SEARCH_DATA_NEEDLE = 2,

  /**
   * Total matches found so far on the active screen: size_t*. Zero
   * until the first feed.
   */
  GHOSTTY_SEARCH_DATA_TOTAL_MATCHES = 3,

  /**
   * Index of the selected match: size_t*. This indexes the newest to
   * oldest ordering of GHOSTTY_SEARCH_DATA_MATCHES, where 0 is the
   * newest match, so a "k of n" find bar renders index + 1 of
   * GHOSTTY_SEARCH_DATA_TOTAL_MATCHES. Returns GHOSTTY_NO_VALUE when
   * nothing is selected.
   */
  GHOSTTY_SEARCH_DATA_SELECTED_INDEX = 4,

  /**
   * The selected match: GhosttySelection*. This is an untracked
   * snapshot with standard GhosttySelection lifetime rules. Returns
   * GHOSTTY_NO_VALUE when nothing is selected.
   */
  GHOSTTY_SEARCH_DATA_SELECTED_MATCH = 5,

  /**
   * All matches on the active screen, ordered newest to oldest, from
   * the bottom of the active area up through scrollback:
   * GhosttySelectionBuffer*. Set ptr to NULL with cap 0 to query the
   * required capacity. An undersized buffer returns
   * GHOSTTY_OUT_OF_SPACE with the required capacity in len.
   */
  GHOSTTY_SEARCH_DATA_MATCHES = 6,

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
  GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES = 7,

  /** Current scroll policy: GhosttySearchScroll*. */
  GHOSTTY_SEARCH_DATA_SELECT_SCROLL = 8,

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
   * Not a real option. ghostty_search_set() returns GHOSTTY_INVALID_VALUE for
   * it. Its value is 0, so a zeroed or uninitialized variable is never
   * mistaken for a real option.
   */
  GHOSTTY_SEARCH_OPT_INVALID = 0,

  /**
   * Set the needle to search for: const GhosttyString*. The bytes are
   * copied, so your memory does not need to outlive the call.
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
   * within the terminal, so you must serialize this with all
   * other access to the same terminal. Returns GHOSTTY_INVALID_VALUE
   * after the terminal was freed.
   */
  GHOSTTY_SEARCH_OPT_NEEDLE = 1,

  /**
   * Set the scroll policy applied by ghostty_search_select_next() and
   * ghostty_search_select_prev(): const GhosttySearchScroll*. The
   * policy persists until changed. A NULL value resets it to
   * GHOSTTY_SEARCH_SCROLL_IF_NEEDED. This only modifies search-owned
   * state and never reads the terminal.
   */
  GHOSTTY_SEARCH_OPT_SELECT_SCROLL = 4,

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
 * any order. You must serialize this call with all other
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
 * the search holds within it, so you must serialize this call
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
 *         search is NULL or the terminal was freed
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
 * This reads the terminal, so you must serialize it with all
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
 * This reads the terminal for the entire call, so you must
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
 * Select the next match, moving toward older content.
 *
 * "Next" goes from the bottom of the screen upward into history, the
 * direction a search from the prompt usually wants. After the oldest
 * match, selection wraps around to the newest one.
 *
 * You can call this at any time, even if the terminal changed since the
 * last feed, because it first brings the search up to date with the
 * terminal. The viewport then scrolls to the selected match as set by
 * GHOSTTY_SEARCH_OPT_SELECT_SCROLL. This reads the terminal, so
 * you must serialize it with all other access to the same terminal.
 *
 * A find bar typically calls this when the user presses Enter, then reads
 * the selected match to highlight it:
 *
 * @code{.c}
 * if (ghostty_search_select_next(search) == GHOSTTY_SUCCESS) {
 *   GhosttySelection match = {0};
 *   ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &match);
 *   // Highlight `match` and show its position in the find bar.
 * }
 * @endcode
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS if a match is now selected, GHOSTTY_NO_VALUE if
 *         there are no matches, GHOSTTY_OUT_OF_MEMORY if allocation fails,
 *         or GHOSTTY_INVALID_VALUE if `search` is NULL or the terminal was
 *         freed
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_select_next(GhosttySearch search);

/**
 * Select the previous match, moving toward newer content.
 *
 * This is the opposite direction of ghostty_search_select_next(). After
 * the newest match, selection wraps around to the oldest one. Everything
 * else, including scrolling and thread safety, works the same as
 * ghostty_search_select_next().
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS if a match is now selected, GHOSTTY_NO_VALUE if
 *         there are no matches, GHOSTTY_OUT_OF_MEMORY if allocation fails,
 *         or GHOSTTY_INVALID_VALUE if `search` is NULL or the terminal was
 *         freed
 *
 * @ingroup search
 */
GHOSTTY_API GhosttyResult ghostty_search_select_prev(GhosttySearch search);

/**
 * Write an option to a search.
 *
 * The value type, and what a NULL value means, depends on the option
 * and is documented by GhosttySearchOption. GHOSTTY_SEARCH_OPT_NEEDLE
 * touches the terminal, so you must serialize it with all other
 * access to the same terminal. GHOSTTY_SEARCH_OPT_SELECT_SCROLL only
 * modifies search-owned state.
 *
 * To move between matches, use ghostty_search_select_next() and
 * ghostty_search_select_prev().
 *
 * @param search Search handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option Option to write
 * @param value Pointer to the input value for the option. The meaning
 *              of NULL is documented per option.
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY if allocation
 *         fails, GHOSTTY_INVALID_VALUE if `search` or `value` is invalid or the
 *         option needs a terminal that was already freed, or
 *         GHOSTTY_UNSUPPORTED if `option` is not known to this version of the
 *         library
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
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the requested data
 *         has no value, GHOSTTY_OUT_OF_SPACE if a provided
 *         GhosttySelectionBuffer is too small (required capacity in its len),
 *         GHOSTTY_OUT_OF_MEMORY if collecting viewport matches fails,
 *         GHOSTTY_INVALID_VALUE if `search` or `value` is invalid, or
 *         GHOSTTY_UNSUPPORTED if `data` is not known to this version of the
 *         library
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
 * Use this when each call into the library is expensive, for example from
 * WebAssembly or from another language through its foreign function
 * interface. It reads every key in one call. From C in the same process it
 * costs the same as calling ghostty_search_get() once per key, so use
 * whichever reads better.
 *
 * Each entry in values must point to storage of the type
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
 * @param keys Data fields to read (NULL returns GHOSTTY_INVALID_VALUE)
 * @param values Output pointers corresponding to keys (NULL returns GHOSTTY_INVALID_VALUE)
 * @param out_written Optional number of fields read, or failing index
 *                    on error
 * @return GHOSTTY_SUCCESS if every key succeeds. Otherwise the result of the
 *         first key that failed, for example GHOSTTY_UNSUPPORTED for a key
 *         that is not known to this version of the library.
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
