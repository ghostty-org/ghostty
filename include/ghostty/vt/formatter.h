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
 * Output format.
 *
 * @ingroup formatter
 */
typedef enum {
  /** Plain text (no escape sequences). */
  GHOSTTY_FORMATTER_FORMAT_PLAIN,

  /** VT sequences preserving colors, styles, URLs, etc. */
  GHOSTTY_FORMATTER_FORMAT_VT,

  /** HTML with inline styles. */
  GHOSTTY_FORMATTER_FORMAT_HTML,
} GhosttyFormatterFormat;

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
 * Opaque handle to a formatter instance.
 *
 * @ingroup formatter
 */
typedef struct GhosttyFormatter* GhosttyFormatter;

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

  /** Whether to trim trailing whitespace on non-blank lines. */
  bool trim;

  /** Extra terminal state to include in styled output. */
  GhosttyFormatterTerminalExtra extra;
} GhosttyFormatterTerminalOptions;

/**
 * Create a formatter for a terminal's active screen.
 *
 * The terminal must outlive the formatter. The formatter stores a borrowed
 * reference to the terminal and reads its current state on each format call.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param formatter Pointer to store the created formatter handle
 * @param terminal The terminal to format (must not be NULL)
 * @param options Formatting options
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup formatter
 */
GhosttyResult ghostty_formatter_terminal_new(
    const GhosttyAllocator* allocator,
    GhosttyFormatter* formatter,
    GhosttyTerminal terminal,
    GhosttyFormatterTerminalOptions options);

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
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup formatter
 */
GhosttyResult ghostty_formatter_format_buf(GhosttyFormatter formatter,
                                           uint8_t* buf,
                                           size_t buf_len,
                                           size_t* out_written);

/**
 * Run the formatter and return an allocated buffer with the output.
 *
 * Each call formats the current terminal state. The buffer is allocated
 * using the provided allocator (or the default allocator if NULL).
 * The caller is responsible for freeing the returned buffer. When using
 * the default allocator (NULL), the buffer can be freed with `free()`.
 * When using a custom allocator, the buffer must be freed using the
 * same allocator.
 *
 * @param formatter The formatter handle (must not be NULL)
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param out_ptr Pointer to receive the allocated buffer
 * @param out_len Pointer to receive the length of the output in bytes
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure
 *
 * @ingroup formatter
 */
GhosttyResult ghostty_formatter_format_alloc(GhosttyFormatter formatter,
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
void ghostty_formatter_free(GhosttyFormatter formatter);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_FORMATTER_H */
