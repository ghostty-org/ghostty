/**
 * @file terminal.h
 *
 * Complete terminal emulator state and rendering.
 */

#ifndef GHOSTTY_VT_TERMINAL_H
#define GHOSTTY_VT_TERMINAL_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/modes.h>
#include <ghostty/vt/grid_ref.h>
#include <ghostty/vt/screen.h>
#include <ghostty/vt/point.h>
#include <ghostty/vt/style.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup terminal Terminal
 *
 * Complete terminal emulator state and rendering.
 *
 * A terminal instance manages the full emulator state including the screen,
 * scrollback, cursor, styles, modes, and VT stream processing.
 *
 * Once a terminal session is up and running, you can configure a key encoder
 * to write keyboard input via ghostty_key_encoder_setopt_from_terminal().
 *
 * @{
 */

/**
 * Opaque handle to a terminal instance.
 *
 * @ingroup terminal
 */
typedef struct GhosttyTerminal* GhosttyTerminal;

/**
 * Terminal initialization options.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Terminal width in cells. Must be greater than zero. */
  uint16_t cols;

  /** Terminal height in cells. Must be greater than zero. */
  uint16_t rows;

  /** Maximum number of lines to keep in scrollback history. */
  size_t max_scrollback;

  // TODO: Consider ABI compatibility implications of this struct.
  // We may want to artificially pad it significantly to support
  // future options.
} GhosttyTerminalOptions;

/**
 * Scroll viewport behavior tag.
 *
 * @ingroup terminal
 */
typedef enum {
  /** Scroll to the top of the scrollback. */
  GHOSTTY_SCROLL_VIEWPORT_TOP,

  /** Scroll to the bottom (active area). */
  GHOSTTY_SCROLL_VIEWPORT_BOTTOM,

  /** Scroll by a delta amount (up is negative). */
  GHOSTTY_SCROLL_VIEWPORT_DELTA,
} GhosttyTerminalScrollViewportTag;

/**
 * Scroll viewport value.
 *
 * @ingroup terminal
 */
typedef union {
  /** Scroll delta (only used with GHOSTTY_SCROLL_VIEWPORT_DELTA). Up is negative. */
  intptr_t delta;

  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[2];
} GhosttyTerminalScrollViewportValue;

/**
 * Tagged union for scroll viewport behavior.
 *
 * @ingroup terminal
 */
typedef struct {
  GhosttyTerminalScrollViewportTag tag;
  GhosttyTerminalScrollViewportValue value;
} GhosttyTerminalScrollViewport;

/**
 * Terminal screen identifier.
 *
 * Identifies which screen buffer is active in the terminal.
 *
 * @ingroup terminal
 */
typedef enum {
  /** The primary (normal) screen. */
  GHOSTTY_TERMINAL_SCREEN_PRIMARY = 0,

  /** The alternate screen. */
  GHOSTTY_TERMINAL_SCREEN_ALTERNATE = 1,
} GhosttyTerminalScreen;

/**
 * Scrollbar state for the terminal viewport.
 *
 * Represents the scrollable area dimensions needed to render a scrollbar.
 *
 * @ingroup terminal
 */
typedef struct {
  /** Total size of the scrollable area in rows. */
  uint64_t total;

  /** Offset into the total area that the viewport is at. */
  uint64_t offset;

  /** Length of the visible area in rows. */
  uint64_t len;
} GhosttyTerminalScrollbar;

/**
 * Terminal data types.
 *
 * These values specify what type of data to extract from a terminal
 * using `ghostty_terminal_get`.
 *
 * @ingroup terminal
 */
typedef enum {
  /** Invalid data type. Never results in any data extraction. */
  GHOSTTY_TERMINAL_DATA_INVALID = 0,

  /**
   * Terminal width in cells.
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_COLS = 1,

  /**
   * Terminal height in cells.
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_ROWS = 2,

  /**
   * Cursor column position (0-indexed).
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_X = 3,

  /**
   * Cursor row position within the active area (0-indexed).
   *
   * Output type: uint16_t *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_Y = 4,

  /**
   * Whether the cursor has a pending wrap (next print will soft-wrap).
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP = 5,

  /**
   * The currently active screen.
   *
   * Output type: GhosttyTerminalScreen *
   */
  GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN = 6,

  /**
   * Whether the cursor is visible (DEC mode 25).
   *
   * Output type: bool *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE = 7,

  /**
   * Current Kitty keyboard protocol flags.
   *
   * Output type: GhosttyKittyKeyFlags * (uint8_t *)
   */
  GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS = 8,

  /**
   * Scrollbar state for the terminal viewport.
   *
   * This may be expensive to calculate depending on where the viewport
   * is (arbitrary pins are expensive). The caller should take care to only
   * call this as needed and not too frequently.
   *
   * Output type: GhosttyTerminalScrollbar *
   */
  GHOSTTY_TERMINAL_DATA_SCROLLBAR = 9,

  /**
   * The current SGR style of the cursor.
   *
   * This is the style that will be applied to newly printed characters.
   *
   * Output type: GhosttyStyle *
   */
  GHOSTTY_TERMINAL_DATA_CURSOR_STYLE = 10,
} GhosttyTerminalData;

/**
 * Create a new terminal instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param terminal Pointer to store the created terminal handle
 * @param options Terminal initialization options
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_new(const GhosttyAllocator* allocator,
                                   GhosttyTerminal* terminal,
                                   GhosttyTerminalOptions options);

/**
 * Free a terminal instance.
 *
 * Releases all resources associated with the terminal. After this call,
 * the terminal handle becomes invalid and must not be used.
 *
 * @param terminal The terminal handle to free (may be NULL)
 *
 * @ingroup terminal
 */
void ghostty_terminal_free(GhosttyTerminal terminal);

/**
 * Perform a full reset of the terminal (RIS).
 *
 * Resets all terminal state back to its initial configuration, including
 * modes, scrollback, scrolling region, and screen contents. The terminal
 * dimensions are preserved.
 *
 * @param terminal The terminal handle (may be NULL, in which case this is a no-op)
 *
 * @ingroup terminal
 */
void ghostty_terminal_reset(GhosttyTerminal terminal);

/**
 * Resize the terminal to the given dimensions.
 *
 * Changes the number of columns and rows in the terminal. The primary
 * screen will reflow content if wraparound mode is enabled; the alternate
 * screen does not reflow. If the dimensions are unchanged, this is a no-op.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param cols New width in cells (must be greater than zero)
 * @param rows New height in cells (must be greater than zero)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_resize(GhosttyTerminal terminal,
                                      uint16_t cols,
                                      uint16_t rows);

/**
 * Write VT-encoded data to the terminal for processing.
 *
 * Feeds raw bytes through the terminal's VT stream parser, updating
 * terminal state accordingly. Only read-only sequences are processed;
 * sequences that require output (queries) are ignored.
 *
 * In the future, a callback-based API will be added to allow handling
 * of output or side effect sequences.
 *
 * This never fails. Any erroneous input or errors in processing the
 * input are logged internally but do not cause this function to fail
 * because this input is assumed to be untrusted and from an external
 * source; so the primary goal is to keep the terminal state consistent and 
 * not allow malformed input to corrupt or crash.
 *
 * @param terminal The terminal handle
 * @param data Pointer to the data to write
 * @param len Length of the data in bytes
 *
 * @ingroup terminal
 */
void ghostty_terminal_vt_write(GhosttyTerminal terminal,
                                const uint8_t* data,
                                size_t len);

/**
 * Scroll the terminal viewport.
 *
 * Scrolls the terminal's viewport according to the given behavior.
 * When using GHOSTTY_SCROLL_VIEWPORT_DELTA, set the delta field in
 * the value union to specify the number of rows to scroll (negative
 * for up, positive for down). For other behaviors, the value is ignored.
 *
 * @param terminal The terminal handle (may be NULL, in which case this is a no-op)
 * @param behavior The scroll behavior as a tagged union
 *
 * @ingroup terminal
 */
void ghostty_terminal_scroll_viewport(GhosttyTerminal terminal,
                                       GhosttyTerminalScrollViewport behavior);

/**
 * Get the current value of a terminal mode.
 *
 * Returns the value of the mode identified by the given mode.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param mode The mode identifying the mode to query
 * @param[out] out_value On success, set to true if the mode is set, false
 *             if it is reset
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the mode does not correspond to a known mode
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_mode_get(GhosttyTerminal terminal,
                                        GhosttyMode mode,
                                        bool* out_value);

/**
 * Set the value of a terminal mode.
 *
 * Sets the mode identified by the given mode to the specified value.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param mode The mode identifying the mode to set
 * @param value true to set the mode, false to reset it
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the mode does not correspond to a known mode
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_mode_set(GhosttyTerminal terminal,
                                         GhosttyMode mode,
                                         bool value);

/**
 * Get data from a terminal instance.
 *
 * Extracts typed data from the given terminal based on the specified
 * data type. The output pointer must be of the appropriate type for the
 * requested data kind. Valid data types and output types are documented
 * in the `GhosttyTerminalData` enum.
 *
 * @param terminal The terminal handle (may be NULL)
 * @param data The type of data to extract
 * @param out Pointer to store the extracted data (type depends on data parameter)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the data type is invalid
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_get(GhosttyTerminal terminal,
                                    GhosttyTerminalData data,
                                    void *out);

/**
 * Resolve a point in the terminal grid to a grid reference.
 *
 * Resolves the given point (which can be in active, viewport, screen,
 * or history coordinates) to a grid reference for that location. Use
 * ghostty_grid_ref_cell() and ghostty_grid_ref_row() to extract the cell
 * and row.
 *
 * Lookups using the `active` and `viewport` tags are fast. The `screen`
 * and `history` tags may require traversing the full scrollback page list
 * to resolve the y coordinate, so they can be expensive for large
 * scrollback buffers.
 *
 * This function isn't meant to be used as the core of render loop. It
 * isn't built to sustain the framerates needed for rendering large screens.
 * Use the render state API for that. This API is instead meant for less
 * strictly performance-sensitive use cases.
 *
 * @param terminal The terminal handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param point The point specifying which cell to look up
 * @param[out] out_ref On success, set to the grid reference at the given point (may be NULL)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if the terminal
 *         is NULL or the point is out of bounds
 *
 * @ingroup terminal
 */
GhosttyResult ghostty_terminal_grid_ref(GhosttyTerminal terminal,
                                        GhosttyPoint point,
                                        GhosttyGridRef *out_ref);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_TERMINAL_H */
