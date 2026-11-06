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

/** @addtogroup formatter
 *
 * A formatter is a view of a terminal that you can turn into plain text, VT
 * sequences, or HTML, as many times as you like.
 *
 * Use one to get text out of a terminal, such as copying a selection or saving
 * what's on the screen. You need a terminal first, and it must outlive the
 * formatter. Each format call reflects the terminal at the time of that call.
 *
 * ## Example
 *
 * @snippet c-vt-formatter/src/main.c formatter-new
 *
 * Full program: @ref c-vt-formatter/src/main.c
 *
 * GhosttyFormatterOption lists the options. See the
 * @ref guide-selection "Selection guide" for copying a selection.
 *
 * @{
 */

/**
 * Terminal state to add to VT output, as a bitmask of
 * GHOSTTY_FORMATTER_EXTRA_* values.
 *
 * VT output is meant to be written to another terminal to recreate the
 * screen. Without extras, it reproduces the text and how each cell is
 * styled. Each extra adds sequences that restore one more piece of terminal
 * state, such as the cursor position or the colors in the palette. Extras
 * are only written when the format is GHOSTTY_FORMATTER_FORMAT_VT. Plain
 * text and HTML output ignore them.
 *
 * Set extras with GHOSTTY_FORMATTER_OPT_EXTRAS. A new formatter uses
 * GHOSTTY_FORMATTER_EXTRAS_DEFAULT. Use GHOSTTY_FORMATTER_EXTRAS_ALL to
 * recreate the terminal as closely as possible.
 *
 * The bits combine with `|`. To change one extra and keep the rest, read the
 * current value first:
 *
 * @code{.c}
 * GhosttyFormatterExtras extras;
 * ghostty_formatter_get(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras);
 *
 * // Also restore the cursor position, but not the palette.
 * extras |= GHOSTTY_FORMATTER_EXTRA_CURSOR;
 * extras &= ~GHOSTTY_FORMATTER_EXTRA_PALETTE;
 *
 * ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EXTRAS, &extras);
 * @endcode
 *
 * @ingroup formatter
 */
typedef uint32_t GhosttyFormatterExtras;

/** Restore the color palette with OSC 4. */
#define GHOSTTY_FORMATTER_EXTRA_PALETTE (1u << 0)
/** Restore terminal modes that differ from their defaults with CSI h and l. */
#define GHOSTTY_FORMATTER_EXTRA_MODES (1u << 1)
/** Restore the scrolling region with DECSTBM and DECSLRM. */
#define GHOSTTY_FORMATTER_EXTRA_SCROLLING_REGION (1u << 2)
/** Restore tab stops by clearing them all and setting each one again. */
#define GHOSTTY_FORMATTER_EXTRA_TABSTOPS (1u << 3)
/** Restore the working directory with OSC 7. */
#define GHOSTTY_FORMATTER_EXTRA_PWD (1u << 4)
/** Restore keyboard modes such as modifyOtherKeys. */
#define GHOSTTY_FORMATTER_EXTRA_KEYBOARD (1u << 5)
/** Restore the cursor position with CUP. */
#define GHOSTTY_FORMATTER_EXTRA_CURSOR (1u << 6)
/** Restore the style the cursor writes new text with, using SGR. */
#define GHOSTTY_FORMATTER_EXTRA_STYLE (1u << 7)
/** Restore the hyperlink the cursor writes new text with, using OSC 8. */
#define GHOSTTY_FORMATTER_EXTRA_HYPERLINK (1u << 8)
/** Restore character protection with DECSCA. */
#define GHOSTTY_FORMATTER_EXTRA_PROTECTION (1u << 9)
/** Restore the Kitty keyboard protocol flags. */
#define GHOSTTY_FORMATTER_EXTRA_KITTY_KEYBOARD (1u << 10)
/** Restore the character sets, such as the line drawing set. */
#define GHOSTTY_FORMATTER_EXTRA_CHARSETS (1u << 11)

/** No extras. VT output has only the text and its styles. */
#define GHOSTTY_FORMATTER_EXTRAS_NONE 0u

/** Every extra. */
#define GHOSTTY_FORMATTER_EXTRAS_ALL 0xFFFu

/**
 * The extras a new formatter starts with: the palette, the cursor style
 * and the cursor hyperlink. These are the extras that affect how output
 * looks.
 */
#define GHOSTTY_FORMATTER_EXTRAS_DEFAULT                                     \
  (GHOSTTY_FORMATTER_EXTRA_PALETTE | GHOSTTY_FORMATTER_EXTRA_STYLE |         \
   GHOSTTY_FORMATTER_EXTRA_HYPERLINK)

/**
 * Formatter options, set with ghostty_formatter_set() and read with
 * ghostty_formatter_get().
 *
 * A new formatter emits plain text with trailing whitespace trimmed. To
 * change that, call ghostty_formatter_set() with a GhosttyFormatterOption
 * and a pointer to the new value. Options stay set across format calls, and
 * a change takes effect on the next one. ghostty_formatter_get() reads an
 * option back.
 *
 * | Option                            | Value type               | Default                            |
 * | --------------------------------- | ------------------------ | ---------------------------------- |
 * | `GHOSTTY_FORMATTER_OPT_EMIT`      | `GhosttyFormatterFormat` | `GHOSTTY_FORMATTER_FORMAT_PLAIN`   |
 * | `GHOSTTY_FORMATTER_OPT_UNWRAP`    | `bool`                   | `false`                            |
 * | `GHOSTTY_FORMATTER_OPT_TRIM`      | `bool`                   | `true`                             |
 * | `GHOSTTY_FORMATTER_OPT_SELECTION` | `GhosttySelection`       | None (the whole screen)            |
 * | `GHOSTTY_FORMATTER_OPT_EXTRAS`    | `GhosttyFormatterExtras` | `GHOSTTY_FORMATTER_EXTRAS_DEFAULT` |
 *
 * Each option lists the type its value points to. To set an option, pass a
 * pointer to a value of that type. To read one, pass a pointer to a
 * variable of that type and the formatter writes the current value there.
 *
 * @ingroup formatter
 */
typedef enum GHOSTTY_ENUM_TYPED {
  /** Not an option. Setting or reading it returns GHOSTTY_INVALID_VALUE. */
  GHOSTTY_FORMATTER_OPT_INVALID = 0,

  /**
   * The output format: plain text, VT sequences, or HTML.
   *
   * Value type: GhosttyFormatterFormat. Default:
   * GHOSTTY_FORMATTER_FORMAT_PLAIN.
   */
  GHOSTTY_FORMATTER_OPT_EMIT = 1,

  /**
   * Join lines that wrapped because they were too long for the screen.
   *
   * When false, each row of the screen is its own line in the output. When
   * true, a line the terminal wrapped onto several rows comes out as one
   * line, the way the program originally wrote it.
   *
   * Value type: bool. Default: false.
   */
  GHOSTTY_FORMATTER_OPT_UNWRAP = 2,

  /**
   * Remove spaces from the end of each line that has other text.
   *
   * Blank lines at the end of the output are always removed. The one
   * exception is VT output with trimming turned off, which keeps them so
   * the output fills the same rows as the screen.
   *
   * Value type: bool. Default: true.
   */
  GHOSTTY_FORMATTER_OPT_TRIM = 3,

  /**
   * Format only the content inside a selection.
   *
   * The formatter keeps its own copy of the selection, so the
   * GhosttySelection you pass doesn't need to stay around. Like any
   * selection, the copy is only valid until the next call that changes the
   * terminal. After the terminal changes, set the selection again before
   * you format, or clear it.
   *
   * Set NULL to clear the selection and format the whole screen again. When
   * no selection is set, ghostty_formatter_get() returns GHOSTTY_NO_VALUE.
   *
   * To format the terminal's active selection, read it with
   * GHOSTTY_TERMINAL_DATA_SELECTION and set it here. For the same text
   * Ghostty copies to the clipboard, use plain output with
   * GHOSTTY_FORMATTER_OPT_UNWRAP and GHOSTTY_FORMATTER_OPT_TRIM both true.
   *
   * @code{.c}
   * // Format only the selected text.
   * ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, &selection);
   * ghostty_formatter_format_alloc(formatter, NULL, &buf, &len);
   *
   * // Go back to formatting the whole screen.
   * ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_SELECTION, NULL);
   * @endcode
   *
   * Value type: GhosttySelection. Default: none, so the whole screen is
   * formatted.
   */
  GHOSTTY_FORMATTER_OPT_SELECTION = 4,

  /**
   * Terminal state to add to VT output. See GhosttyFormatterExtras.
   *
   * Value type: GhosttyFormatterExtras. Default:
   * GHOSTTY_FORMATTER_EXTRAS_DEFAULT.
   */
  GHOSTTY_FORMATTER_OPT_EXTRAS = 5,

  GHOSTTY_FORMATTER_OPT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyFormatterOption;

/**
 * Create a formatter for a terminal's active screen.
 *
 * The terminal must outlive the formatter. The formatter stores a borrowed
 * reference to the terminal and reads its current state on each format call.
 *
 * The new formatter starts with the default for every option, as listed on
 * GhosttyFormatterOption. Change them with ghostty_formatter_set().
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param formatter Pointer to store the created formatter handle (NULL
 *                  returns GHOSTTY_INVALID_VALUE)
 * @param terminal The terminal to format (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_terminal_new(
    const GhosttyAllocator* allocator,
    GhosttyFormatter* formatter,
    GhosttyTerminal terminal);

/**
 * Set a formatter option.
 *
 * `value` points to the option's new value. Its type is listed on each
 * GhosttyFormatterOption. The formatter copies the value, so it only has
 * to be valid during the call. The change applies to every format call
 * after this one.
 *
 * Passing NULL for `value` puts the option back to its default, the same
 * value a new formatter starts with.
 *
 * @code{.c}
 * GhosttyFormatterFormat emit = GHOSTTY_FORMATTER_FORMAT_HTML;
 * ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit);
 *
 * // Later, go back to the default (plain text).
 * ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, NULL);
 * @endcode
 *
 * If the call fails, the option keeps its previous value.
 *
 * @param formatter The formatter handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to set
 * @param value Pointer to the new value, or NULL to reset the option to its
 *              default
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `formatter`
 *         is NULL or the value is not valid for the option (such as an
 *         unknown format, an extras bit with no meaning, or a selection
 *         with a zeroed grid reference), or GHOSTTY_UNSUPPORTED if
 *         `option` is not known to this version of the library
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_set(GhosttyFormatter formatter,
                                                GhosttyFormatterOption option,
                                                const void* value);

/**
 * Read the current value of a formatter option.
 *
 * `out` points to a variable of the type listed on the option. On success
 * the formatter writes the option's value there.
 *
 * @code{.c}
 * bool trim;
 * ghostty_formatter_get(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &trim);
 * @endcode
 *
 * @param formatter The formatter handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param option The option to read
 * @param out Pointer that receives the value (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_NO_VALUE if the option is
 *         not set (only possible for GHOSTTY_FORMATTER_OPT_SELECTION),
 *         GHOSTTY_INVALID_VALUE if `formatter` or `out` is NULL, or
 *         GHOSTTY_UNSUPPORTED if `option` is not known to this version of
 *         the library
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_get(GhosttyFormatter formatter,
                                                GhosttyFormatterOption option,
                                                void* out);

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
 * function does not flush or make your destination durable.
 *
 * @param formatter The formatter handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param writer Destination writer whose write callback must not be NULL
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_IO_ERROR if the writer rejects
 *         output, GHOSTTY_LIMIT_EXCEEDED if output accounting overflows, or
 *         GHOSTTY_INVALID_VALUE if an argument is invalid
 *
 * @ingroup formatter
 */
GHOSTTY_API GhosttyResult ghostty_formatter_format(
    GhosttyFormatter formatter,
    GhosttyWriter writer);

/**
 * Run the formatter and produce output into your buffer.
 *
 * Each call formats the current terminal state. Pass NULL for buf to
 * query the required buffer size without writing any output. out_written
 * receives the required size and the return value is GHOSTTY_OUT_OF_SPACE.
 *
 * Empty output needs no space, so that query returns GHOSTTY_SUCCESS with a
 * size of 0 instead. Handle both results:
 *
 * @code{.c}
 * size_t needed = 0;
 * GhosttyResult result = ghostty_formatter_format_buf(formatter, NULL, 0, &needed);
 * if (result == GHOSTTY_SUCCESS) return; // Nothing to format.
 * if (result != GHOSTTY_OUT_OF_SPACE) return; // A real error.
 *
 * uint8_t* buf = malloc(needed);
 * size_t written = 0;
 * result = ghostty_formatter_format_buf(formatter, buf, needed, &written);
 * @endcode
 *
 * If the buffer is too small, returns GHOSTTY_OUT_OF_SPACE and sets
 * out_written to the required size. You can then retry with a
 * larger buffer.
 *
 * @param formatter The formatter handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param buf Pointer to the output buffer, or NULL to query size
 * @param buf_len Length of the output buffer in bytes
 * @param out_written Pointer to receive the number of bytes written,
 *                    or the required size on failure (NULL returns
 *                    GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, or an error code on failure
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
 * You are responsible for freeing the returned buffer with
 * ghostty_free(), passing the same allocator (or NULL for the default)
 * that was used for the allocation.
 * Empty output returns GHOSTTY_SUCCESS with *out_ptr set to NULL and
 * *out_len set to zero. This result can be passed to ghostty_free().
 *
 * @param formatter The formatter handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param out_ptr Pointer to receive the allocated buffer (NULL returns
 *                GHOSTTY_INVALID_VALUE)
 * @param out_len Pointer to receive the length of the output in bytes (NULL
 *                returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 *         failure, GHOSTTY_INVALID_VALUE if an output pointer is NULL
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
