/**
 * @file formatter.h
 *
 * Format terminal content as plain text, VT sequences, or HTML.
 */

#ifndef GHOSTTY_VT_FORMATTER_H
#define GHOSTTY_VT_FORMATTER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/io.h>
#include <ghostty/vt/selection.h>
#include <ghostty/vt/types.h>
#include <ghostty/vt/terminal.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup formatter Formatter
 *
 * Format terminal content as plain text, VT sequences, or HTML.
 *
 * A formatter captures a reference to a terminal and formatting options.
 * It can be used repeatedly to produce output that reflects the current
 * terminal state at the time of each format call.
 *
 * The terminal must outlive the formatter.
 *
 * @{
 */

/**
 * Extra screen state to include in styled output.
 *
 * @ingroup formatter
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyFormatterScreenExtra). */
  size_t size;

  /** Emit cursor position using CUP (CSI H). */
  bool cursor;

  /** Emit current SGR style state based on the cursor's active style_id. */
  bool style;

  /** Emit current hyperlink state using OSC 8 sequences. */
  bool hyperlink;

  /** Emit character protection mode using DECSCA. */
  bool protection;

  /** Emit Kitty keyboard protocol state using CSI > u and CSI = sequences. */
  bool kitty_keyboard;

  /** Emit character set designations and invocations. */
  bool charsets;
} GhosttyFormatterScreenExtra;

/**
 * Extra terminal state to include in styled output.
 *
 * @ingroup formatter
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyFormatterTerminalExtra). */
  size_t size;

  /** Emit the palette using OSC 4 sequences. */
  bool palette;

  /** Emit terminal modes that differ from their defaults using CSI h/l. */
  bool modes;

  /** Emit scrolling region state using DECSTBM and DECSLRM sequences. */
  bool scrolling_region;

  /** Emit tabstop positions by clearing all tabs and setting each one. */
  bool tabstops;

  /** Emit the present working directory using OSC 7. */
  bool pwd;

  /** Emit keyboard modes such as ModifyOtherKeys. */
  bool keyboard;

  /** Screen-level extras. */
  GhosttyFormatterScreenExtra screen;
} GhosttyFormatterTerminalExtra;

/**
 * Options for creating a terminal formatter.
 *
 * @ingroup formatter
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyFormatterTerminalOptions). */
  size_t size;

  /** Output format to emit. */
  GhosttyFormatterFormat emit;

  /** Whether to unwrap soft-wrapped lines. */
  bool unwrap;

  /**
   * Whether to trim trailing whitespace on non-blank lines. Trailing blank
   * lines are always trimmed, except in VT output without trimming, where
   * they are kept as part of the layout.
   */
  bool trim;

  /** Extra terminal state to include in styled output. */
  GhosttyFormatterTerminalExtra extra;

  /** Optional selection to restrict output to a range. Its grid
   *  references must be in the active screen when formatting: each format
   *  call checks that they are in a page of that screen and returns
   *  GHOSTTY_INVALID_VALUE if not (for example after a switch to the
   *  other screen). The references must also be current: no mutating
   *  terminal call may have occurred between producing them and the
   *  format call, so take them (and create the formatter) after the
   *  terminal's last update. A stale reference is not reliably detected:
   *  the format may select other cells than intended. If NULL, the entire
   *  screen is formatted. */
  const GhosttySelection *selection;
} GhosttyFormatterTerminalOptions;

/**
 * Options for creating a screen formatter.
 *
 * @ingroup formatter
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyFormatterScreenOptions). */
  size_t size;

  /** Output format to emit. */
  GhosttyFormatterFormat emit;

  /** Whether to unwrap soft-wrapped lines. */
  bool unwrap;

  /** Whether to trim trailing whitespace on non-blank lines. */
  bool trim;

  /** Extra screen state to include in styled output. */
  GhosttyFormatterScreenExtra extra;

  /** Optional selection to restrict output to a range. Its grid
   *  references must be in the formatted screen, see
   *  ghostty_terminal_screen_grid_ref(): each format call checks that they
   *  are in a page of that screen and returns GHOSTTY_INVALID_VALUE if
   *  not. The references must also be current: no mutating terminal call
   *  may have occurred between producing them and the format call, so take
   *  them (and create the formatter) after the terminal's last update. A
   *  stale reference is not reliably detected: the format may select other
   *  cells than intended. If NULL, the entire screen is formatted. */
  const GhosttySelection *selection;
} GhosttyFormatterScreenOptions;

/**
 * Create a formatter for a terminal's active screen.
 *
 * The terminal must outlive the formatter. The formatter stores a borrowed
 * reference to the terminal and reads its current state on each format call.
 *
 * To format a screen whether or not it is active, see
 * ghostty_formatter_screen_new().
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param formatter Pointer to store the created formatter handle
 * @param terminal The terminal to format (must not be NULL)
 * @param options Formatting options
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_terminal_new(
    const GhosttyAllocator* allocator,
    GhosttyFormatter* formatter,
    GhosttyTerminal terminal,
    GhosttyFormatterTerminalOptions options);

/**
 * Create a formatter for one of a terminal's screens.
 *
 * Where ghostty_formatter_terminal_new() formats whichever screen is
 * active, this formats the given screen whether or not it is active, so
 * the primary screen and its scrollback can be formatted while a program
 * has the alternate screen up. The screen is looked up on each format
 * call: formatting returns GHOSTTY_NO_VALUE while the screen is not
 * initialized (the alternate screen exists once a program has switched
 * to it, and is discarded by a full reset).
 *
 * The output holds the screen's contents and the screen extras (cursor,
 * style, hyperlink, protection, Kitty keyboard, charsets). Terminal state
 * such as the palette, modes, tabstops and the scrolling region belongs to
 * the terminal formatter; combine the two to reconstruct a terminal with
 * both screens. The cursor position counts from the top-left of the
 * screen, as CUP does outside origin mode (DECOM), so it should be
 * replayed before the terminal formatter's modes and scrolling region.
 *
 * The terminal must outlive the formatter. The formatter stores a borrowed
 * reference to the terminal and reads its current state on each format call.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param formatter Pointer to store the created formatter handle
 * @param terminal The terminal whose screen to format (must not be NULL)
 * @param screen The screen to format
 * @param options Formatting options
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_screen_new(
    const GhosttyAllocator* allocator,
    GhosttyFormatter* formatter,
    GhosttyTerminal terminal,
    GhosttyTerminalScreen screen,
    GhosttyFormatterScreenOptions options);

/**
 * Run the formatter and stream output to a writer.
 *
 * Each call formats the current terminal state and invokes the writer
 * synchronously as output becomes available. The callback may be called more
 * than once and must not call formatter or terminal APIs using the same
 * formatter or its terminal.
 *
 * If an error occurs, the writer may already contain a partial formatted
 * output. The operation cannot be resumed from that partial output. This
 * function does not flush or make the caller's destination durable.
 *
 * @param formatter The formatter handle (must not be NULL)
 * @param writer Destination writer whose write callback must not be NULL
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR if the writer rejects
 *         output, GHOSTTY_LIMIT_EXCEEDED if output accounting overflows,
 *         GHOSTTY_INVALID_VALUE if an argument is invalid or the
 *         selection's grid references are not in the formatted screen, or
 *         GHOSTTY_NO_VALUE if a screen formatter's screen is not initialized
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_format(
    GhosttyFormatter formatter,
    GhosttyWriter writer);

/**
 * Run the formatter and produce output into the caller-provided buffer.
 *
 * Each call formats the current terminal state. Pass NULL for buf to
 * query the required buffer size without writing any output; in that case
 * out_written receives the required size and the return value is
 * GHOSTTY_OUT_OF_SPACE.
 *
 * If the buffer is too small, returns GHOSTTY_OUT_OF_SPACE and sets
 * out_written to the required size. The caller can then retry with a
 * larger buffer.
 *
 * @param formatter The formatter handle (must not be NULL)
 * @param buf Pointer to the output buffer, or NULL to query size
 * @param buf_len Length of the output buffer in bytes
 * @param out_written Pointer to receive the number of bytes written,
 *                    or the required size on failure
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if a screen
 *         formatter's screen is not initialized, GHOSTTY_INVALID_VALUE if
 *         the selection's grid references are not in the formatted screen
 *         (out_written is then zero), or an error code on failure
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_format_buf(GhosttyFormatter formatter,
                                           uint8_t* buf,
                                           size_t buf_len,
                                           size_t* out_written);

/**
 * Run the formatter and return an allocated buffer with the output.
 *
 * Each call formats the current terminal state. The buffer is allocated
 * using the provided allocator (or the default allocator if NULL).
 * The caller is responsible for freeing the returned buffer with
 * ghostty_free(), passing the same allocator (or NULL for the default)
 * that was used for the allocation.
 * Empty output returns GHOSTTY_SUCCESS with *out_ptr set to NULL and
 * *out_len set to zero. This result can be passed to ghostty_free().
 *
 * @param formatter The formatter handle (must not be NULL)
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param out_ptr Pointer to receive the allocated buffer
 * @param out_len Pointer to receive the length of the output in bytes
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, GHOSTTY_NO_VALUE if a screen formatter's screen is not
 *         initialized, GHOSTTY_INVALID_VALUE if the selection's grid
 *         references are not in the formatted screen
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_format_alloc(GhosttyFormatter formatter,
                                             const GhosttyAllocator* allocator,
                                             uint8_t** out_ptr,
                                             size_t* out_len);

/**
 * Free a formatter instance.
 *
 * Releases all resources associated with the formatter. After this call,
 * the formatter handle becomes invalid.
 *
 * @param formatter The formatter handle to free (may be NULL)
 *
 * @ingroup formatter
 */
GHOSTTY_API void ghostty_formatter_free(GhosttyFormatter formatter);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_FORMATTER_H */
